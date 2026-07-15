import Foundation
import CryptoKit
import whisper

/// From libggml (ggml-backend.h, not re-exported through whisper.h): loads the compute
/// backend plugins (Metal/CPU) from a directory. Brew's ggml is a dynamic-backend build,
/// and nothing loads the plugins for us — without this, whisper_init aborts with
/// GGML_ASSERT(device).
@_silgen_name("ggml_backend_load_all_from_path")
private func ggml_backend_load_all_from_path(_ path: UnsafePointer<CChar>?)

/// Native multilingual ASR via whisper.cpp (Metal). Used for Urdu/mixed dictation —
/// Apple's on-device recognizer has no Urdu model. Batch: transcribes the full capture
/// at release (large-v3-turbo q5_0 runs ~5-10x realtime on Apple Silicon).
public final class WhisperTranscriber: @unchecked Sendable {
    public static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"
    public static let modelDownloadURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    /// ~574 MB
    public static let modelExpectedBytes: Int64 = 574_000_000
    /// Pinned upstream digest (huggingface.co/ggerganov/whisper.cpp LFS oid) — downloads
    /// failing this check are discarded.
    public static let modelSHA256 =
        "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"

    public static var modelURL: URL {
        AppSettings.supportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelFileName)
    }

    public static var modelInstalled: Bool {
        // Guard against truncated downloads: require at least 90% of expected size.
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: modelURL.path)[.size] as? Int64 else { return false }
        return size > modelExpectedBytes * 9 / 10
    }

    private let context: OpaquePointer
    private let queue = DispatchQueue(label: "skvoice.whisper")

    /// ggml loads its compute backends (Metal, CPU) as plugins at runtime; point it at
    /// them before the first init. Bundled copy first, Homebrew install as fallback.
    /// Backend plugins are loaded ONLY from fixed, trusted locations: the app bundle
    /// (signed with the app) or the Homebrew install. Deliberately no environment-variable
    /// override — an env-controlled dylib directory would be an arbitrary-code-execution
    /// vector in a process holding Accessibility permissions.
    private static let configureBackends: Void = {
        let candidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ggml-backends").path,
            "/opt/homebrew/opt/ggml/libexec",
        ]
        for candidate in candidates.compactMap({ $0 })
        where FileManager.default.fileExists(atPath: candidate) {
            candidate.withCString { ggml_backend_load_all_from_path($0) }
            return
        }
    }()

    /// Loads the model (~1-2 s once); keep the instance alive across captures.
    public init(modelPath: String = WhisperTranscriber.modelURL.path) throws {
        _ = Self.configureBackends
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Transcribes 16 kHz mono samples. `language`: ISO code ("ur", "en") or "auto".
    public func transcribe(samples: [Float], language: String = "auto") throws -> String {
        guard samples.count >= 3200 else { return "" } // < 0.2 s — nothing to hear
        return try queue.sync {
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_progress = false
            params.print_realtime = false
            params.print_special = false
            params.print_timestamps = false
            params.suppress_blank = true
            params.no_timestamps = true
            params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

            let result: Int32 = language.withCString { lang in
                var p = params
                if language != "auto" { p.language = lang }
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, p, buffer.baseAddress, Int32(buffer.count))
                }
            }
            guard result == 0 else { throw WhisperError.transcriptionFailed(Int(result)) }

            var text = ""
            for index in 0..<whisper_full_n_segments(context) {
                if let segment = whisper_full_get_segment_text(context, index) {
                    text += String(cString: segment)
                }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

public enum WhisperError: Error, LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): "Whisper model failed to load: \(path)"
        case .transcriptionFailed(let code): "Whisper transcription failed (code \(code))"
        }
    }
}

/// Downloads the whisper model with progress, resumable via URLSession.
@MainActor
public final class WhisperModelDownloader: NSObject, ObservableObject {
    @Published public var progress: Double = 0
    @Published public var downloading = false
    @Published public var errorText: String?

    public static let shared = WhisperModelDownloader()

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// Streaming SHA-256 so the 574 MB file never fully loads into memory.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func start() {
        guard !downloading, !WhisperTranscriber.modelInstalled else { return }
        downloading = true
        errorText = nil
        progress = 0

        let destination = WhisperTranscriber.modelURL
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(
            with: WhisperTranscriber.modelDownloadURL) { temporary, _, error in
            Task { @MainActor in
                defer { self.downloading = false }
                if let error {
                    self.errorText = error.localizedDescription
                    return
                }
                guard let temporary else {
                    self.errorText = "Download failed"
                    return
                }
                do {
                    // Integrity gate: reject anything that doesn't match the pinned digest.
                    let digest = try Self.sha256(of: temporary)
                    guard digest == WhisperTranscriber.modelSHA256 else {
                        try? FileManager.default.removeItem(at: temporary)
                        self.errorText = "Model failed integrity check — download discarded."
                        return
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    self.progress = 1
                } catch {
                    self.errorText = error.localizedDescription
                }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                self.progress = progress.fractionCompleted
            }
        }
        self.task = task
        task.resume()
    }
}
