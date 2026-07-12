import XCTest
@testable import SKVoiceCore

final class VocabularyProcessorTests: XCTestCase {
    func testCaseInsensitivePhraseReplacement() {
        let p = VocabularyProcessor(rules: [
            VocabRule(find: "sk note taker", replace: "SK Note Taker")
        ])
        XCTAssertEqual(p.apply("open Sk Note Taker now"), "open SK Note Taker now")
    }

    func testWordBoundaryRespected() {
        let p = VocabularyProcessor(rules: [VocabRule(find: "cat", replace: "Catherine")])
        XCTAssertEqual(p.apply("the cat sat"), "the Catherine sat")
        XCTAssertEqual(p.apply("concatenate strings"), "concatenate strings")
    }

    func testLongestRuleWinsWhenOverlapping() {
        let p = VocabularyProcessor(rules: [
            VocabRule(find: "note", replace: "NOTE"),
            VocabRule(find: "note taker", replace: "Note Taker"),
        ])
        XCTAssertEqual(p.apply("my note taker app"), "my Note Taker app")
        XCTAssertEqual(p.apply("a quick note here"), "a quick NOTE here")
    }

    func testPunctuationAdjacency() {
        let p = VocabularyProcessor(rules: [VocabRule(find: "saqib", replace: "Saqib")])
        XCTAssertEqual(p.apply("thanks saqib, see you"), "thanks Saqib, see you")
        XCTAssertEqual(p.apply("is that saqib?"), "is that Saqib?")
    }

    func testEmptyRulesPassThrough() {
        XCTAssertEqual(VocabularyProcessor(rules: []).apply("unchanged"), "unchanged")
    }

    func testMultipleOccurrences() {
        let p = VocabularyProcessor(rules: [VocabRule(find: "api", replace: "API")])
        XCTAssertEqual(p.apply("the api calls another api"), "the API calls another API")
    }

    func testRegexMetacharactersInFindAreEscaped() {
        let p = VocabularyProcessor(rules: [VocabRule(find: "c++", replace: "C++")])
        XCTAssertEqual(p.apply("i write c++ code"), "i write C++ code")
    }
}
