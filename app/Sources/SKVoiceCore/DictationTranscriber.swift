import Foundation
import Speech
import AVFoundation

/// One-shot dictation transcription via on-device SpeechAnalyzer/SpeechTranscriber.
/// Lifecycle per capture: `start()` at Fn-down (runs concurrently with recording),
/// `feed()` for each 16 kHz mono chunk, `finish()` at release returns the full text.
///
/// Lessons inherited from SK Note Taker's TranscriptionService:
/// - keep ONE persistent AVAudioConverter across feeds (stateful resampling),
/// - after finalizeAndFinishThroughEndOfInput, DRAIN the results consumer rather than
///   cancelling it, or the trailing final results are silently dropped.
public actor DictationTranscriber {
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var consumeTask: Task<Void, Never>?
    private var feedConverter: AVAudioConverter?
    private var finals: [String] = []

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Ensures the on-device model for the locale is installed (system-wide download).
    public static func ensureModel(locale: Locale = Locale(identifier: "en-US")) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            throw DictationError.localeUnsupported(locale.identifier)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    public func start() async throws {
        finals = []
        feedConverter = nil

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],           // finals only — dictation needs no volatiles
            attributeOptions: [])
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        consumeTask = Task { [weak self] in
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        await self?.append(text)
                    }
                }
            } catch {
                FileHandle.standardError.write(
                    Data("SKVoice: transcriber stream ended: \(error)\n".utf8))
            }
        }
    }

    private func append(_ text: String) {
        finals.append(text)
    }

    /// Feed a 16 kHz mono chunk.
    public func feed(_ samples: [Float]) {
        guard let format = analyzerFormat,
              let mono = AudioResampler.buffer(from: samples) else { return }
        let buffer: AVAudioPCMBuffer
        if format == mono.format {
            buffer = mono
        } else {
            if feedConverter == nil {
                feedConverter = AVAudioConverter(from: mono.format, to: format)
                feedConverter?.primeMethod = .none
            }
            guard let converter = feedConverter else { return }
            let ratio = format.sampleRate / mono.format.sampleRate
            let cap = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up) + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var served = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true; status.pointee = .haveData; return mono
            }
            guard convError == nil, out.frameLength > 0 else { return }
            buffer = out
        }
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Finalize and return the concatenated transcript.
    public func finish() async -> String {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await consumeTask?.value
        consumeTask = nil
        analyzer = nil
        transcriber = nil
        feedConverter = nil
        return finals.joined(separator: " ")
    }

    /// Abandon an in-flight capture (short-tap cancel).
    public func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        consumeTask?.cancel()
        consumeTask = nil
        analyzer = nil
        transcriber = nil
        feedConverter = nil
        finals = []
    }
}

public enum DictationError: Error, LocalizedError {
    case localeUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let id): "Transcription locale not supported: \(id)"
        }
    }
}
