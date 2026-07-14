import XCTest
import Synchronization
@testable import SKVoiceCore

final class AudioDuckerTests: XCTestCase {
    /// Fake volume world: a mutable volume plus a call flag.
    final class FakeAudio: @unchecked Sendable {
        let volume = Mutex<Float?>(0.8)
        let setCalls = Mutex<[Float]>([])

        var backend: AudioDucker.Backend {
            AudioDucker.Backend(
                getVolume: { [self] in volume.withLock { $0 } },
                setVolume: { [self] newValue in
                    guard volume.withLock({ $0 }) != nil else { return false }
                    volume.withLock { $0 = newValue }
                    setCalls.withLock { $0.append(newValue) }
                    return true
                })
        }
    }

    func testDuckLowersAndRestorePutsBack() {
        let audio = FakeAudio()
        let ducker = AudioDucker(backend: audio.backend, duckLevel: 0.1)

        ducker.duck()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.1)
        ducker.restore()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.8)
    }

    func testDuckAppliesEvenDuringCalls() {
        // Explicit user preference: dictating mid-call ducks the other participants
        // so only the user's voice is heard while recording.
        let audio = FakeAudio()
        let ducker = AudioDucker(backend: audio.backend, duckLevel: 0.1)
        ducker.duck()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.1)
        ducker.restore()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.8)
    }

    func testDuckSkippedWhenVolumeAlreadyLow() {
        let audio = FakeAudio()
        audio.volume.withLock { $0 = 0.05 }
        let ducker = AudioDucker(backend: audio.backend, duckLevel: 0.1)

        ducker.duck()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.05)
        ducker.restore()
        XCTAssertEqual(audio.setCalls.withLock { $0 }, [])
    }

    func testDoubleDuckDoesNotOverwriteSavedVolume() {
        let audio = FakeAudio()
        let ducker = AudioDucker(backend: audio.backend, duckLevel: 0.1)

        ducker.duck()
        ducker.duck() // second duck must not save 0.1 as the "previous" volume
        ducker.restore()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.8)
    }

    func testRestoreWithoutDuckIsNoOp() {
        let audio = FakeAudio()
        AudioDucker(backend: audio.backend).restore()
        XCTAssertEqual(audio.setCalls.withLock { $0 }, [])
    }

    func testNoVolumeControlIsGracefulNoOp() {
        let audio = FakeAudio()
        audio.volume.withLock { $0 = nil } // e.g. HDMI output
        let ducker = AudioDucker(backend: audio.backend)

        ducker.duck()
        ducker.restore()
        XCTAssertEqual(audio.setCalls.withLock { $0 }, [])
    }

    func testDuckRestoreCycleRepeats() {
        let audio = FakeAudio()
        let ducker = AudioDucker(backend: audio.backend, duckLevel: 0.1)

        ducker.duck()
        ducker.restore()
        audio.volume.withLock { $0 = 0.5 }
        ducker.duck()
        ducker.restore()
        XCTAssertEqual(audio.volume.withLock { $0 }, 0.5)
    }
}

final class SettingsMigrationTests: XCTestCase {
    func testOldSettingsFileWithoutNewKeysKeepsUserData() throws {
        // A v1.1 settings file: no duckWhileDictating key.
        let old = """
        {"holdThreshold":0.45,"refineSystemPrompt":"custom prompt","modelOverride":"haiku",
         "vocabulary":[{"id":"1","find":"saqib","replace":"Saqib"}],"hotkeysPaused":false}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data(old.utf8).write(to: url)

        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded.holdThreshold, 0.45)
        XCTAssertEqual(loaded.refineSystemPrompt, "custom prompt")
        XCTAssertEqual(loaded.vocabulary.count, 1, "old vocabulary must survive migration")
        XCTAssertTrue(loaded.duckWhileDictating, "new field defaults on")
    }
}
