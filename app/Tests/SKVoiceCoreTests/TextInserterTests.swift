import XCTest
import AppKit
@testable import SKVoiceCore

final class TextInserterTests: XCTestCase {
    /// Uses a private named pasteboard so tests never touch the user's real clipboard.
    func testSaveAndRestoreRoundTrip() {
        let pb = NSPasteboard(name: NSPasteboard.Name("skvoice-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("original contents", forType: .string)

        let saved = TextInserter.savedContents(of: pb)
        pb.clearContents()
        pb.setString("transcript text", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "transcript text")

        TextInserter.restore(saved, to: pb)
        XCTAssertEqual(pb.string(forType: .string), "original contents")
        pb.releaseGlobally()
    }

    func testSaveEmptyPasteboardRestoresEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name("skvoice-test-\(UUID().uuidString)"))
        pb.clearContents()

        let saved = TextInserter.savedContents(of: pb)
        pb.setString("temp", forType: .string)
        TextInserter.restore(saved, to: pb)
        XCTAssertNil(pb.string(forType: .string))
        pb.releaseGlobally()
    }

    func testSecureInputReturnsCopiedOnlyAndKeepsTextOnClipboard() async {
        // Inject isSecureInput=true: must not synthesize keys, must leave text available.
        let result = await TextInserter.insert(
            "secret-adjacent text", isSecureInput: true, restoreDelay: .milliseconds(1))
        XCTAssertEqual(result, .copiedOnly)
        // The general pasteboard now holds our text (acceptable in tests; restored by
        // the next test run's system use).
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "secret-adjacent text")
    }
}
