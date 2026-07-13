import XCTest
@testable import SKVoiceCore

final class SidecarProtocolTests: XCTestCase {
    func testPingEncodesToNDJSON() throws {
        let data = try SidecarRequest.ping(id: "p1").encoded()
        XCTAssertEqual(data.last, 0x0A)
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: String]
        XCTAssertEqual(object, ["id": "p1", "type": "ping"])
    }

    func testRefineEncodesAllFields() throws {
        let data = try SidecarRequest.refine(
            id: "r1", transcript: "hello", context: "ctx", appName: "Slack").encoded()
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: String]
        XCTAssertEqual(object?["type"], "refine")
        XCTAssertEqual(object?["transcript"], "hello")
        XCTAssertEqual(object?["context"], "ctx")
        XCTAssertEqual(object?["appName"], "Slack")
    }

    func testDecodePong() {
        let line = Data(#"{"id":"a","type":"pong"}"#.utf8)
        XCTAssertEqual(SidecarResponse.decode(line: line), .pong(id: "a"))
    }

    func testDecodeResult() {
        let line = Data(#"{"id":"b","type":"result","text":"Hi there"}"#.utf8)
        XCTAssertEqual(SidecarResponse.decode(line: line), .result(id: "b", text: "Hi there"))
    }

    func testDecodeError() {
        let line = Data(#"{"id":"c","type":"error","message":"boom"}"#.utf8)
        XCTAssertEqual(SidecarResponse.decode(line: line), .error(id: "c", message: "boom"))
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(SidecarResponse.decode(line: Data("not json".utf8)))
        XCTAssertNil(SidecarResponse.decode(line: Data(#"{"id":"x","type":"dance"}"#.utf8)))
        XCTAssertNil(SidecarResponse.decode(line: Data(#"{"type":"pong"}"#.utf8)))
    }

    func testUnicodeSurvivesRoundTrip() throws {
        let text = "Héllo — “smart quotes” and émoji 🎤"
        let data = try SidecarRequest.refine(
            id: "u1", transcript: text, context: "", appName: "").encoded()
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: String]
        XCTAssertEqual(object?["transcript"], text)
    }
}
