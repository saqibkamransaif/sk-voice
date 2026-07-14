import Foundation
import Speech
import AVFoundation
import AppKit
import SKVoiceCore

/// Diagnostic CLI for the SK Voice pipeline, mirroring sknote-audiocheck.
/// Subcommands:
///   wav <path>        transcribe a WAV file through the app's ASR path
///   mic [seconds]     record from the default mic and transcribe (default 4 s)
///   context           print the frontmost window's captured screen context
///   sidecar <text>    round-trip a refine request through the sidecar

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("skvoice-check: \(message)\n".utf8))
    exit(1)
}

func loadSamples(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let frames = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: frames) else {
        throw NSError(domain: "skvoice-check", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
    }
    try file.read(into: buffer)
    return AudioResampler().resample(buffer)
}

func transcribe(samples: [Float]) async throws -> String {
    let transcriber = DictationTranscriber()
    try await transcriber.start()
    let chunk = 4_000
    var index = 0
    while index < samples.count {
        let end = min(index + chunk, samples.count)
        await transcriber.feed(Array(samples[index..<end]))
        index = end
    }
    return await transcriber.finish()
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: skvoice-check <wav|mic|context|sidecar> [args]")
}

switch args[1] {
case "wav":
    guard args.count >= 3 else { fail("usage: skvoice-check wav <path>") }
    let url = URL(fileURLWithPath: args[2])
    do {
        try await DictationTranscriber.ensureModel()
        let samples = try loadSamples(url: url)
        let seconds = Double(samples.count) / AudioResampler.targetRate
        print("loaded \(samples.count) samples (\(String(format: "%.1f", seconds)) s)")
        let start = Date()
        let text = try await transcribe(samples: samples)
        let elapsed = Date().timeIntervalSince(start)
        print("transcript (\(String(format: "%.2f", elapsed)) s): \(text)")
    } catch {
        fail("\(error.localizedDescription)")
    }

case "mic":
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 4) : 4
    guard await MicRecorder.permissionGranted() else { fail("mic permission denied") }
    do {
        try await DictationTranscriber.ensureModel()
        let recorder = MicRecorder()
        try recorder.prewarm()
        let transcriber = DictationTranscriber()
        try await transcriber.start()
        print("recording \(seconds) s — speak now…")
        recorder.beginCapture { samples in
            Task { await transcriber.feed(samples) }
        }
        try await Task.sleep(for: .seconds(seconds))
        recorder.endCapture()
        let text = await transcriber.finish()
        print("transcript: \(text)")
    } catch {
        fail("\(error.localizedDescription)")
    }

case "whisper":
    guard args.count >= 3 else { fail("usage: skvoice-check whisper <wav> [lang]") }
    guard WhisperTranscriber.modelInstalled else {
        fail("model not installed at \(WhisperTranscriber.modelURL.path)")
    }
    let lang = args.count >= 4 ? args[3] : "auto"
    do {
        let samples = try loadSamples(url: URL(fileURLWithPath: args[2]))
        print("loading model…")
        let start = Date()
        let whisper = try WhisperTranscriber()
        let loaded = Date()
        let text = try whisper.transcribe(samples: samples, language: lang)
        let done = Date()
        print("model load: \(String(format: "%.2f", loaded.timeIntervalSince(start))) s")
        print("transcribe: \(String(format: "%.2f", done.timeIntervalSince(loaded))) s")
        print("text [\(lang)]: \(text)")
    } catch {
        fail("\(error.localizedDescription)")
    }

case "locales":
    let supported = await SpeechTranscriber.supportedLocales
    print("supported transcription locales (\(supported.count)):")
    for locale in supported.sorted(by: { $0.identifier < $1.identifier }) {
        print("  \(locale.identifier(.bcp47))")
    }

case "duck":
    let before = SystemVolume.get()
    print("volume before: \(before.map { String(format: "%.2f", $0) } ?? "no software control")")
    print("call active: \(CallDetection.callAppIsUsingMic())")
    print("mic users: \(CallDetection.bundleIdsUsingMic())")
    let ducker = AudioDucker()
    ducker.duck()
    print("volume ducked: \(SystemVolume.get().map { String(format: "%.2f", $0) } ?? "?")")
    try? await Task.sleep(for: .milliseconds(600))
    ducker.restore()
    print("volume restored: \(SystemVolume.get().map { String(format: "%.2f", $0) } ?? "?")")

case "context":
    let captured = ScreenContext.capture()
    print("app: \(captured.appName.isEmpty ? "<none>" : captured.appName)")
    print("window: \(captured.windowTitle)")
    let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let mode = TargetClassifier.classify(bundleID: bundleID, appName: captured.appName,
                                         windowTitle: captured.windowTitle)
    print("classified mode: \(mode.rawValue)")
    print("text (\(captured.text.utf8.count) bytes):")
    print(captured.text)

case "sidecar":
    guard args.count >= 3 else { fail("usage: skvoice-check sidecar <text>") }
    let transcript = args[2...].joined(separator: " ")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Default sidecar dir: repo layout relative to the app package.
    let sidecarDir = ProcessInfo.processInfo.environment["SKVOICE_SIDECAR_DIR"]
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent().appendingPathComponent("sidecar").path
    let client = SidecarClient(
        socketPath: "\(home)/.skvoice/sidecar.sock",
        nodePath: nil,
        sidecarDir: sidecarDir,
        requestTimeout: .seconds(30))
    await client.start()
    do {
        let start = Date()
        let text = try await client.refine(
            transcript: transcript, context: "", appName: "skvoice-check")
        let elapsed = Date().timeIntervalSince(start)
        print("refined (\(String(format: "%.2f", elapsed)) s): \(text)")
    } catch {
        await client.stop()
        fail("sidecar error: \(error.localizedDescription)")
    }
    await client.stop()

default:
    fail("unknown subcommand \(args[1])")
}
