import XCTest
@testable import SKVoiceCore

final class TranscriptPostProcessorTests: XCTestCase {
    let plain = TranscriptPostProcessor(snippets: [])

    // MARK: - Commands

    func testNewLineInline() {
        XCTAssertEqual(plain.apply("first item new line second item"),
                       "first item\nsecond item")
    }

    func testNewParagraphInline() {
        XCTAssertEqual(plain.apply("intro done. New paragraph now the details"),
                       "intro done.\n\nnow the details")
    }

    func testCommandWithSurroundingPunctuation() {
        // ASR often renders "…, new line, …" with commas or a trailing period.
        XCTAssertEqual(plain.apply("buy milk, new line, buy eggs"),
                       "buy milk\nbuy eggs")
        XCTAssertEqual(plain.apply("Hello. New paragraph. Regards"),
                       "Hello.\n\nRegards")
    }

    func testMultipleCommands() {
        XCTAssertEqual(plain.apply("one new line two new line three"),
                       "one\ntwo\nthree")
    }

    func testNewlineWordAloneIsNotACommandInsideOtherWords() {
        XCTAssertEqual(plain.apply("the newline character is special"),
                       "the newline character is special")
    }

    // MARK: - Scratch that

    func testScratchThatDropsEverythingBefore() {
        XCTAssertEqual(plain.apply("send it tomorrow scratch that send it today"),
                       "send it today")
    }

    func testScratchThatAtEndDiscardsCapture() {
        XCTAssertNil(plain.apply("never mind all of this scratch that"))
        XCTAssertNil(plain.apply("scratch that."))
    }

    func testLastScratchThatWins() {
        XCTAssertEqual(plain.apply("a scratch that b scratch that c"), "c")
    }

    func testScratchThatWithPunctuation() {
        XCTAssertEqual(plain.apply("wrong text. Scratch that. Right text"), "Right text")
    }

    // MARK: - Snippets

    let snippets = [
        SnippetRule(trigger: "insert signature",
                    template: "Best regards,\nSaqib Kamran\nsaqibkamran.com"),
        SnippetRule(trigger: "insert calendly",
                    template: "https://calendly.com/example/30min"),
    ]

    func testSnippetAlone() {
        let p = TranscriptPostProcessor(snippets: snippets)
        XCTAssertEqual(p.apply("insert signature"),
                       "Best regards,\nSaqib Kamran\nsaqibkamran.com")
    }

    func testSnippetInline() {
        let p = TranscriptPostProcessor(snippets: snippets)
        XCTAssertEqual(
            p.apply("you can book me here insert calendly looking forward"),
            "you can book me here https://calendly.com/example/30min looking forward")
    }

    func testSnippetCaseAndPunctuationTolerant() {
        let p = TranscriptPostProcessor(snippets: snippets)
        XCTAssertEqual(p.apply("Thanks! Insert signature."),
                       "Thanks! Best regards,\nSaqib Kamran\nsaqibkamran.com")
    }

    func testSnippetCombinedWithCommands() {
        let p = TranscriptPostProcessor(snippets: snippets)
        XCTAssertEqual(
            p.apply("see you then new paragraph insert signature"),
            "see you then\n\nBest regards,\nSaqib Kamran\nsaqibkamran.com")
    }

    // MARK: - Passthrough

    func testPlainTextUntouched() {
        XCTAssertEqual(plain.apply("just a normal sentence with nothing special"),
                       "just a normal sentence with nothing special")
    }

    func testEmptyInputIsNil() {
        XCTAssertNil(plain.apply("   "))
    }
}
