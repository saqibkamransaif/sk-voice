import XCTest
import AVFoundation
@testable import SKVoiceCore

final class PreRollBufferTests: XCTestCase {
    func testKeepsOnlyMostRecentCapacity() {
        var buffer = PreRollBuffer(seconds: 0.001, sampleRate: 1000) // capacity 1
        buffer.append([1, 2, 3])
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.drain(), [3])
    }

    func testDrainReturnsAndClears() {
        var buffer = PreRollBuffer(seconds: 1, sampleRate: 10)
        buffer.append([1, 2])
        XCTAssertEqual(buffer.drain(), [1, 2])
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.drain(), [])
    }

    func testRollingWindowAcrossChunks() {
        var buffer = PreRollBuffer(seconds: 0.004, sampleRate: 1000) // capacity 4
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        XCTAssertEqual(buffer.drain(), [3, 4, 5, 6])
    }
}

final class AudioStoreTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        let id = "test-\(UUID().uuidString)"
        defer { AudioStore.delete(for: id) }

        // One second of a 440 Hz tone at 16 kHz.
        let samples = (0..<16_000).map { Float(sin(2 * .pi * 440 * Double($0) / 16_000)) * 0.5 }
        XCTAssertTrue(AudioStore.save(samples: samples, for: id))
        XCTAssertTrue(AudioStore.hasAudio(for: id))

        let file = try AVAudioFile(forReading: AudioStore.url(for: id))
        XCTAssertEqual(Double(file.length), 16_000, accuracy: 32)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }

    func testDeleteRemovesFile() {
        let id = "test-\(UUID().uuidString)"
        AudioStore.save(samples: [0.1, 0.2, 0.3], for: id)
        AudioStore.delete(for: id)
        XCTAssertFalse(AudioStore.hasAudio(for: id))
    }

    func testSaveEmptyIsRejected() {
        XCTAssertFalse(AudioStore.save(samples: [], for: "never"))
    }
}

final class TranscriberBufferingTests: XCTestCase {
    /// Chunks fed BEFORE start() must be buffered, not dropped — this was the
    /// clipped-first-word accuracy bug.
    func testChunksFedBeforeStartAreTranscribed() async throws {
        try await DictationTranscriber.ensureModel()
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "hello", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = try DictationTranscriberTests.loadSamples(url: url)

        let transcriber = DictationTranscriber()
        // Feed the FIRST half before start() — simulates audio arriving while the
        // analyzer spins up.
        let midpoint = samples.count / 2
        await transcriber.feed(Array(samples[..<midpoint]))
        try await transcriber.start()
        await transcriber.feed(Array(samples[midpoint...]))
        let text = await transcriber.finish().lowercased()

        XCTAssertTrue(text.contains("hello"), "first-half words lost: \(text)")
        XCTAssertTrue(text.contains("test"), "second-half words lost: \(text)")
    }
}
