import XCTest
@testable import SKVoiceCore

final class StyleLearnerTests: XCTestCase {
    func testShouldLearnEveryTenthInsert() {
        XCTAssertFalse(StyleLearner.shouldLearn(insertCount: 0))
        XCTAssertFalse(StyleLearner.shouldLearn(insertCount: 9))
        XCTAssertTrue(StyleLearner.shouldLearn(insertCount: 10))
        XCTAssertFalse(StyleLearner.shouldLearn(insertCount: 11))
        XCTAssertTrue(StyleLearner.shouldLearn(insertCount: 20))
    }

    func testPairsOnlyFromChangedRefines() {
        let entries = [
            HistoryEntry(mode: .refine, rawTranscript: "tell him ok",
                         finalText: "Sounds good!", appName: "Messages",
                         durationSeconds: 1),
            HistoryEntry(mode: .dictation, rawTranscript: "plain dictation",
                         finalText: "plain dictation", appName: "Notes",
                         durationSeconds: 1),
            HistoryEntry(mode: .refine, rawTranscript: "unchanged",
                         finalText: "unchanged", appName: "Mail", durationSeconds: 1),
            HistoryEntry(mode: .refine, rawTranscript: "", finalText: "x",
                         appName: "Mail", durationSeconds: 1),
        ]
        let pairs = StyleLearner.pairs(from: entries)
        XCTAssertEqual(pairs, [StylePair(raw: "tell him ok", final: "Sounds good!")])
    }

    func testPairsLimit() {
        let entries = (0..<20).map {
            HistoryEntry(mode: .refine, rawTranscript: "raw \($0)",
                         finalText: "final \($0)", appName: "A", durationSeconds: 1)
        }
        XCTAssertEqual(StyleLearner.pairs(from: entries, limit: 5).count, 5)
    }

    func testLearnRequestEncodes() throws {
        let data = try SidecarRequest.learn(
            id: "l1", pairs: [StylePair(raw: "a", final: "b")],
            currentProfile: "profile").encoded()
        let object = try JSONSerialization.jsonObject(with: data.dropLast())
            as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "learn")
        XCTAssertEqual(object?["currentProfile"] as? String, "profile")
        let pairs = object?["pairs"] as? [[String: String]]
        XCTAssertEqual(pairs, [["raw": "a", "final": "b"]])
    }

    func testStyleHintEncodesOnRefineAndRevise() throws {
        let refine = try SidecarRequest.refine(
            id: "r", transcript: "t", context: "", appName: "", mode: .message,
            styleHint: "short sentences").encoded()
        let refineObject = try JSONSerialization.jsonObject(with: refine.dropLast())
            as? [String: Any]
        XCTAssertEqual(refineObject?["styleHint"] as? String, "short sentences")

        let revise = try SidecarRequest.revise(
            id: "v", draft: "d", instruction: "i", context: "", appName: "",
            mode: .prompt, styleHint: "emoji ok").encoded()
        let reviseObject = try JSONSerialization.jsonObject(with: revise.dropLast())
            as? [String: Any]
        XCTAssertEqual(reviseObject?["styleHint"] as? String, "emoji ok")
    }
}
