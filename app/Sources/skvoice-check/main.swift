import Foundation
import AVFoundation
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

case "context":
    let captured = ScreenContext.capture()
    print("app: \(captured.appName.isEmpty ? "<none>" : captured.appName)")
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
