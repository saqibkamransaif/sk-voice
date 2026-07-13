import Foundation

/// Spawns the Node sidecar and talks NDJSON to it over a Unix domain socket.
/// One request in flight at a time (the coordinator serializes refines anyway).
public actor SidecarClient {
    public enum ClientError: Error, LocalizedError {
        case notConnected
        case timeout
        case sidecar(String)
        case protocolViolation

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Sidecar is not connected"
            case .timeout: "Sidecar request timed out"
            case .sidecar(let message): "Sidecar error: \(message)"
            case .protocolViolation: "Sidecar protocol violation"
            }
        }
    }

    private let socketPath: String
    private let nodePath: String?
    private let sidecarDir: String
    private let requestTimeout: Duration
    private var settingsProvider: (@Sendable () -> (systemPrompt: String, model: String?))?

    private var process: Process?
    private var fd: Int32 = -1
    private var readBuffer = Data()
    private var restartDelay: TimeInterval = 1
    private var stopped = false

    public init(socketPath: String, nodePath: String?, sidecarDir: String,
                requestTimeout: Duration = .seconds(8)) {
        self.socketPath = socketPath
        self.nodePath = nodePath
        self.sidecarDir = sidecarDir
        self.requestTimeout = requestTimeout
    }

    /// Supplies the refine system prompt / model override at spawn time.
    public func configure(settings: @escaping @Sendable () -> (systemPrompt: String, model: String?)) {
        settingsProvider = settings
    }

    // MARK: - Lifecycle

    public func start() {
        stopped = false
        spawnIfNeeded()
        _ = connectWithRetry(attempts: 20, delay: 0.25)
    }

    public func stop() {
        stopped = true
        disconnect()
        process?.terminate()
        process = nil
    }

    public func isHealthy() async -> Bool {
        if let response = try? await send(.ping(id: UUID().uuidString)),
           case .pong = response {
            return true
        }
        return false
    }

    /// Restart the sidecar process (settings changed, or manual restart from UI).
    public func restart() {
        stop()
        stopped = false
        start()
    }

    private func spawnIfNeeded() {
        guard process == nil || process?.isRunning != true else { return }

        let node = nodePath ?? Self.findNode()
        let script = "\(sidecarDir)/dist/index.js"
        guard FileManager.default.fileExists(atPath: script),
              let node else {
            log("cannot spawn sidecar (node: \(nodePath ?? "not found"), script: \(script))")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script]
        var environment = ProcessInfo.processInfo.environment
        environment["SKVOICE_SOCKET"] = socketPath
        if let settings = settingsProvider?() {
            environment["SKVOICE_SYSTEM_PROMPT"] = settings.systemPrompt
            if let model = settings.model { environment["SKVOICE_MODEL"] = model }
        }
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let logPath = AppSettings.supportDirectory.appendingPathComponent("sidecar.log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            p.standardOutput = handle
            p.standardError = handle
        }
        p.terminationHandler = { [weak self] _ in
            Task { await self?.handleProcessExit() }
        }
        do {
            try p.run()
            process = p
            restartDelay = 1
            log("sidecar spawned (pid \(p.processIdentifier))")
        } catch {
            log("sidecar spawn failed: \(error)")
        }
    }

    private func handleProcessExit() async {
        disconnect()
        process = nil
        guard !stopped else { return }
        log("sidecar exited; restarting in \(restartDelay)s")
        try? await Task.sleep(for: .seconds(restartDelay))
        restartDelay = min(restartDelay * 2, 8)
        guard !stopped else { return }
        spawnIfNeeded()
        _ = connectWithRetry(attempts: 20, delay: 0.25)
    }

    /// Finds node: explicit path, PATH lookup, then common install locations (incl. nvm).
    public static func findNode() -> String? {
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["bash", "-lc", "command -v node"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        if (try? which.run()) != nil {
            which.waitUntilExit()
            if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) {
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // nvm: newest installed version.
        let nvm = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path),
           let newest = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first {
            let path = nvm.appendingPathComponent("\(newest)/bin/node").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Socket

    private func connectWithRetry(attempts: Int, delay: TimeInterval) -> Bool {
        for _ in 0..<attempts {
            if connect() { return true }
            Thread.sleep(forTimeInterval: delay)
        }
        log("could not connect to \(socketPath)")
        return false
    }

    private func connect() -> Bool {
        disconnect()
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketFD)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(
                    start: source.baseAddress, count: source.count))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, size)
            }
        }
        guard result == 0 else {
            close(socketFD)
            return false
        }
        fd = socketFD
        return true
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        readBuffer.removeAll()
    }

    // MARK: - Requests

    public func refine(transcript: String, context: String, appName: String,
                       mode: RefineMode = .message) async throws -> String {
        try await roundTrip(.refine(
            id: UUID().uuidString, transcript: transcript, context: context,
            appName: appName, mode: mode))
    }

    public func revise(draft: String, instruction: String, context: String,
                       appName: String, mode: RefineMode) async throws -> String {
        try await roundTrip(.revise(
            id: UUID().uuidString, draft: draft, instruction: instruction,
            context: context, appName: appName, mode: mode))
    }

    private func roundTrip(_ request: SidecarRequest) async throws -> String {
        let response = try await send(request)
        switch response {
        case .result(_, let text): return text
        case .error(_, let message): throw ClientError.sidecar(message)
        case .pong: throw ClientError.protocolViolation
        }
    }

    private func send(_ request: SidecarRequest) async throws -> SidecarResponse {
        if fd < 0 {
            spawnIfNeeded()
            guard connectWithRetry(attempts: 8, delay: 0.25) else {
                throw ClientError.notConnected
            }
        }
        let payload = try request.encoded()
        let written = payload.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == payload.count else {
            disconnect()
            throw ClientError.notConnected
        }

        let deadline = ContinuousClock.now + requestTimeout
        while ContinuousClock.now < deadline {
            if let line = nextLine() {
                guard let response = SidecarResponse.decode(line: line) else {
                    throw ClientError.protocolViolation
                }
                if response.id == request.id { return response }
                continue // stale response from a timed-out predecessor — skip
            }
            let received = try readChunk(until: deadline)
            if !received {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw ClientError.timeout
    }

    private func nextLine() -> Data? {
        guard let newline = readBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = readBuffer.prefix(upTo: newline)
        readBuffer.removeSubrange(...newline)
        return Data(line)
    }

    /// Non-blocking-ish read with a short poll timeout; returns whether bytes arrived.
    private func readChunk(until deadline: ContinuousClock.Instant) throws -> Bool {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMS = Int32(50)
        let ready = poll(&pollFD, 1, timeoutMS)
        guard ready > 0, pollFD.revents & Int16(POLLIN) != 0 else { return false }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            readBuffer.append(contentsOf: buffer[0..<count])
            return true
        }
        // 0 = EOF (sidecar closed); negative = error.
        disconnect()
        throw ClientError.notConnected
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("SKVoice sidecar-client: \(message)\n".utf8))
    }
}
