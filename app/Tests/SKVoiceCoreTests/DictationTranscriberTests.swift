import XCTest
import AVFoundation
@testable import SKVoiceCore

final class DictationTranscriberTests: XCTestCase {
    func testTranscribesWavFixture() async throws {
        try await DictationTranscriber.ensureModel()

        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "hello", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = try Self.loadSamples(url: url)
        XCTAssertGreaterThan(samples.count, 16_000, "fixture should exceed one second")

        let transcriber = DictationTranscriber()
        try await transcriber.start()
        // Feed in ~0.25 s chunks to mimic live capture.
        let chunk = 4_000
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            await transcriber.feed(Array(samples[index..<end]))
            index = end
        }
        let text = await transcriber.finish().lowercased()

        XCTAssertTrue(text.contains("hello"), "transcript was: \(text)")
        XCTAssertTrue(text.contains("test"), "transcript was: \(text)")
    }

    /// Loads a WAV as 16 kHz mono Float32 via the same resampler the app uses.
    static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "fixture", code: 1)
        }
        try file.read(into: buffer)
        return AudioResampler().resample(buffer)
    }
}
