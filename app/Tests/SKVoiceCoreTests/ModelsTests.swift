import XCTest
@testable import SKVoiceCore

final class ModelsTests: XCTestCase {
    func testSettingsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("settings.json")

        var settings = AppSettings()
        settings.holdThreshold = 0.45
        settings.modelOverride = "haiku"
        settings.vocabulary = [VocabRule(find: "sk note taker", replace: "SK Note Taker")]
        try settings.save(to: url)

        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded, settings)
    }

    func testLoadMissingFileReturnsDefaults() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded, AppSettings())
    }

    func testDefaultRefinePromptNonEmpty() {
        XCTAssertFalse(AppSettings.defaultRefinePrompt.isEmpty)
        XCTAssertTrue(AppSettings().refineSystemPrompt.contains("ONLY the message text"))
    }
}
