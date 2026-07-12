import XCTest
@testable import SKVoiceCore

final class HistoryStoreTests: XCTestCase {
    var path = ""
    var store: HistoryStore!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("skvoice-test-\(UUID().uuidString).db").path
        store = try HistoryStore(path: path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    func entry(_ text: String, mode: CaptureMode = .dictation,
               createdAt: Date = Date()) -> HistoryEntry {
        HistoryEntry(mode: mode, rawTranscript: text, finalText: text,
                     appName: "TestApp", durationSeconds: 1.5, createdAt: createdAt)
    }

    func testSaveAndRecentRoundTrip() throws {
        let e = entry("hello world")
        try store.save(e)
        let loaded = store.recent(limit: 10, search: nil)
        XCTAssertEqual(loaded, [e])
    }

    func testOrderingNewestFirst() throws {
        let old = entry("old", createdAt: Date(timeIntervalSinceNow: -100))
        let new = entry("new")
        try store.save(old)
        try store.save(new)
        XCTAssertEqual(store.recent(limit: 10, search: nil).map(\.finalText), ["new", "old"])
    }

    func testSearchFiltersOnFinalText() throws {
        try store.save(entry("send the invoice tomorrow"))
        try store.save(entry("walk the dog"))
        let hits = store.recent(limit: 10, search: "invoice")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].finalText.contains("invoice"))
    }

    func testDelete() throws {
        let e = entry("to be deleted")
        try store.save(e)
        try store.delete(id: e.id)
        XCTAssertEqual(store.count(), 0)
    }

    func testLimitRespected() throws {
        for i in 0..<5 { try store.save(entry("entry \(i)")) }
        XCTAssertEqual(store.recent(limit: 3, search: nil).count, 3)
        XCTAssertEqual(store.count(), 5)
    }

    func testRefineModePersistsBothTexts() throws {
        let e = HistoryEntry(mode: .refine, rawTranscript: "tell him im late",
                             finalText: "Hi John, I'm running about 10 minutes late.",
                             appName: "Messages", durationSeconds: 2.0, createdAt: Date())
        try store.save(e)
        let loaded = store.recent(limit: 1, search: nil)[0]
        XCTAssertEqual(loaded.mode, .refine)
        XCTAssertEqual(loaded.rawTranscript, "tell him im late")
        XCTAssertNotEqual(loaded.rawTranscript, loaded.finalText)
    }
}
