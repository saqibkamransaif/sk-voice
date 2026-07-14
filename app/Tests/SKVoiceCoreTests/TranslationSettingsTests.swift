import XCTest
@testable import SKVoiceCore

final class TranslationSettingsTests: XCTestCase {
    func testDefaultsAreEnglishNoTranslation() {
        let settings = AppSettings()
        XCTAssertEqual(settings.dictationLanguage, "en-US")
        XCTAssertFalse(settings.translationActive)
        XCTAssertEqual(settings.asrLocale.identifier, "en-US")
    }

    func testUrduMixedImpliesTranslationAndIndianEnglishASR() {
        var settings = AppSettings()
        settings.dictationLanguage = "urdu-mixed"
        XCTAssertTrue(settings.translationActive)
        XCTAssertEqual(settings.asrLocale.identifier, "en-IN",
                       "no Urdu on-device locale — en-IN acoustics + Claude reconstruction")
    }

    func testExplicitToggleActivatesTranslationForEnglish() {
        var settings = AppSettings()
        settings.translateToEnglish = true
        XCTAssertTrue(settings.translationActive)
        XCTAssertEqual(settings.asrLocale.identifier, "en-US")
    }

    func testTranslateInstructionCoversReconstruction() {
        XCTAssertTrue(AppSettings.translateInstruction.contains("Urdu"))
        XCTAssertTrue(AppSettings.translateInstruction.contains("ENGLISH"))
        XCTAssertTrue(AppSettings.translateInstruction.contains("phonetic"))
    }

    func testOldSettingsFileMigratesWithDefaults() throws {
        let old = #"{"holdThreshold":0.3,"refineSystemPrompt":"p","vocabulary":[],"hotkeysPaused":false}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data(old.utf8).write(to: url)
        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded.dictationLanguage, "en-US")
        XCTAssertFalse(loaded.translateToEnglish)
        XCTAssertTrue(loaded.keepAudioRecordings)
    }
}
