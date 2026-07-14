import Foundation
import AVFoundation
import Synchronization

/// Always-warm microphone capture. The engine starts once at app launch (`prewarm()`) and
/// keeps running; `beginCapture`/`endCapture` just open and close a gate on the permanent
/// tap. This is what makes Fn-down feel instant — there is no engine spin-up on the hot path.
///
/// NEVER enable voice processing here: VPIO without an output render chain delivers silence
/// (see docs/research.md §2). Dictation needs no echo cancellation.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler = AudioResampler()
    private let onChunk = Mutex<(@Sendable ([Float]) -> Void)?>(nil)
    private let lastLevel = Mutex<Float>(0)
    /// Rolling last ~0.6 s of audio, prepended at beginCapture so words spoken a beat
    /// before the hotkey landed aren't lost.
    private let preRoll = Mutex<PreRollBuffer>(PreRollBuffer())
    private var prewarmed = false

    public init() {}

    /// 0…1 RMS of the most recent chunk while capturing (drives the waveform UI).
    public var inputLevel: Float { lastLevel.withLock { $0 } }

    public static func permissionGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Start the engine with a permanent tap. Call once at launch (after mic permission).
    public func prewarm() throws {
        guard !prewarmed else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.noInput("no microphone input (format \(format))")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            let samples = resampler.resample(buffer)
            guard !samples.isEmpty else { return }
            guard let handler = onChunk.withLock({ $0 }) else {
                // Not capturing — keep the rolling pre-roll warm.
                preRoll.withLock { $0.append(samples) }
                return
            }
            let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
                .squareRoot()
            lastLevel.withLock { $0 = rms }
            handler(samples)
        }
        engine.prepare()
        try engine.start()
        prewarmed = true
    }

    /// Restart after a device change or engine stall.
    public func recover() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        prewarmed = false
        try? prewarm()
    }

    public func beginCapture(onChunk handler: @escaping @Sendable ([Float]) -> Void) {
        let buffered = preRoll.withLock { $0.drain() }
        if !buffered.isEmpty {
            handler(buffered)
        }
        onChunk.withLock { $0 = handler }
    }

    public func endCapture() {
        onChunk.withLock { $0 = nil }
        lastLevel.withLock { $0 = 0 }
    }
}

public enum MicRecorderError: Error, LocalizedError {
    case noInput(String)

    public var errorDescription: String? {
        switch self {
        case .noInput(let detail): "Microphone unavailable: \(detail)"
        }
    }
}
