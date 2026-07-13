import Foundation
import SwiftUI
import AppKit
import UserNotifications
import AVFoundation
import IOKit.hid
import ApplicationServices
import SKVoiceCore

/// Floating bar / menu bar visual state.
enum BarState: Equatable {
    case idle
    case recording(mode: CaptureMode)
    case transcribing
    case refining
    case error(String)
}

/// Orchestrates the whole pipeline. Owns every core component and reacts to hotkey actions.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var barState: BarState = .idle
    @Published var inputLevel: Float = 0
    @Published var settings: AppSettings
    @Published var sidecarHealthy = false
    @Published var permissionsComplete: Bool
    @Published var historyRevision = 0   // bumped after each save so views refresh

    let history: HistoryStore?
    private let recorder = MicRecorder()
    private let sidecar: SidecarClient
    private var monitor: HotkeyMonitor?
    private var transcriber: DictationTranscriber?
    private var captureStart = Date()
    private var levelTimer: Timer?
    private var currentContext: (appName: String, text: String) = ("", "")
    private var contextTask: Task<Void, Never>?

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        permissionsComplete = Permissions.allGranted()

        history = try? HistoryStore(
            path: AppSettings.supportDirectory.appendingPathComponent("history.db").path)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        sidecar = SidecarClient(
            socketPath: "\(home)/.skvoice/sidecar.sock",
            nodePath: nil,
            sidecarDir: Self.bundledSidecarDir())
    }

    /// Resources/sidecar inside the app bundle; falls back to the repo layout for dev runs.
    static func bundledSidecarDir() -> String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("sidecar").path,
           FileManager.default.fileExists(atPath: "\(bundled)/dist/index.js") {
            return bundled
        }
        // swift run from app/: ../sidecar
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent().appendingPathComponent("sidecar").path
    }

    // MARK: - Lifecycle

    func startServices() {
        guard permissionsComplete else { return }

        do {
            try recorder.prewarm()
        } catch {
            barState = .error("Mic unavailable")
            logError("prewarm failed: \(error)")
        }

        Task {
            try? await DictationTranscriber.ensureModel()
        }

        let prompt = settings.refineSystemPrompt
        let model = settings.modelOverride
        Task {
            await sidecar.configure { (systemPrompt: prompt, model: model) }
            await sidecar.start()
            sidecarHealthy = await sidecar.isHealthy()
        }

        let monitor = HotkeyMonitor(holdThreshold: settings.holdThreshold) { [weak self] action in
            Task { @MainActor in
                self?.handle(action: action)
            }
        }
        monitor.isPaused = settings.hotkeysPaused
        if !monitor.start() {
            barState = .error("Enable Input Monitoring")
            logError("event tap creation failed — missing Input Monitoring permission?")
        }
        self.monitor = monitor
    }

    func refreshPermissions() {
        let granted = Permissions.allGranted()
        if granted != permissionsComplete {
            permissionsComplete = granted
            if granted { startServices() }
        }
    }

    func applySettingsChange() {
        try? settings.save()
        monitor?.updateThreshold(settings.holdThreshold)
        monitor?.isPaused = settings.hotkeysPaused
        let prompt = settings.refineSystemPrompt
        let model = settings.modelOverride
        Task {
            await sidecar.configure { (systemPrompt: prompt, model: model) }
            await sidecar.restart()
            sidecarHealthy = await sidecar.isHealthy()
        }
    }

    func restartSidecar() {
        Task {
            await sidecar.restart()
            sidecarHealthy = await sidecar.isHealthy()
        }
    }

    func shutdown() {
        monitor?.stop()
        Task { await sidecar.stop() }
    }

    // MARK: - Hotkey pipeline

    private func handle(action: HotkeyAction) {
        switch action {
        case .start(let mode):
            beginCapture(mode: mode)
        case .upgradeToRefine:
            barState = .recording(mode: .refine)
            captureScreenContext()
        case .finish(let mode):
            endCapture(mode: mode)
        case .cancel:
            cancelCapture()
        }
    }

    private func beginCapture(mode: CaptureMode) {
        captureStart = Date()
        barState = .recording(mode: mode)
        currentContext = ("", "")

        let transcriber = DictationTranscriber()
        self.transcriber = transcriber

        Task {
            try? await transcriber.start()
        }
        recorder.beginCapture { samples in
            Task { await transcriber.feed(samples) }
        }

        if mode == .refine {
            captureScreenContext()
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inputLevel = self.recorder.inputLevel
            }
        }
    }

    private func captureScreenContext() {
        contextTask?.cancel()
        contextTask = Task.detached { [weak self] in
            let context = ScreenContext.capture()
            await MainActor.run { self?.currentContext = context }
        }
    }

    private func endCapture(mode: CaptureMode) {
        recorder.endCapture()
        stopLevelTimer()
        guard let transcriber else {
            barState = .idle
            return
        }
        self.transcriber = nil
        let duration = Date().timeIntervalSince(captureStart)
        barState = mode == .refine ? .refining : .transcribing

        let vocabulary = VocabularyProcessor(rules: settings.vocabulary)
        let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        Task {
            let raw = await transcriber.finish()
            guard !raw.isEmpty else {
                self.flashError("Heard nothing")
                return
            }
            let transcript = vocabulary.apply(raw)

            switch mode {
            case .dictation:
                await self.deliver(text: transcript, raw: raw, mode: .dictation,
                                   appName: targetApp, duration: duration)
            case .refine:
                await self.refineAndDeliver(transcript: transcript, raw: raw,
                                            appName: targetApp, duration: duration)
            }
        }
    }

    private func refineAndDeliver(transcript: String, raw: String,
                                  appName: String, duration: Double) async {
        do {
            let refined = try await sidecar.refine(
                transcript: transcript,
                context: currentContext.text,
                appName: currentContext.appName.isEmpty ? appName : currentContext.appName)
            await deliver(text: refined, raw: raw, mode: .refine,
                          appName: appName, duration: duration)
        } catch {
            // Never leave the user empty-handed: paste the raw transcript instead.
            logError("refine failed, falling back to raw transcript: \(error)")
            notify(title: "Refine unavailable",
                   body: "Pasted your raw dictation instead. (\(error.localizedDescription))")
            await deliver(text: transcript, raw: raw, mode: .refine,
                          appName: appName, duration: duration)
            sidecarHealthy = await sidecar.isHealthy()
        }
    }

    private func deliver(text: String, raw: String, mode: CaptureMode,
                         appName: String, duration: Double) async {
        let result = await TextInserter.insert(text)
        if result == .copiedOnly {
            notify(title: "Copied to clipboard",
                   body: "A secure field was focused, so SK Voice didn't type into it.")
        }
        let entry = HistoryEntry(mode: mode, rawTranscript: raw, finalText: text,
                                 appName: appName, durationSeconds: duration)
        try? history?.save(entry)
        historyRevision += 1
        barState = .idle
    }

    private func cancelCapture() {
        recorder.endCapture()
        stopLevelTimer()
        contextTask?.cancel()
        if let transcriber {
            self.transcriber = nil
            Task { await transcriber.cancel() }
        }
        barState = .idle
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
    }

    private func flashError(_ message: String) {
        barState = .error(message)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if case .error = self.barState { self.barState = .idle }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func logError(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = AppSettings.supportDirectory.appendingPathComponent("errors.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
        FileHandle.standardError.write(Data("SKVoice: \(message)\n".utf8))
    }
}

/// Permission checks used by onboarding and startup.
enum Permissions {
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func allGranted() -> Bool {
        microphoneGranted() && accessibilityGranted() && inputMonitoringGranted()
    }
}
