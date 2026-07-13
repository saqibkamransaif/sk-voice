import XCTest
@testable import SKVoiceCore

final class SidecarClientTests: XCTestCase {
    var tempDir: URL!
    var socketPath: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skvoice-sidecar-test-\(UUID().uuidString)")
        // Stage the fake sidecar as <dir>/dist/index.js — same layout the client expects.
        let dist = tempDir.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let fake = try XCTUnwrap(Bundle.module.url(
            forResource: "fake-sidecar", withExtension: "js", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(
            at: fake, to: dist.appendingPathComponent("index.js"))
        // Unix socket paths are capped at 104 bytes on macOS; temp dirs are too deep.
        socketPath = "/tmp/skv-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func makeClient(timeout: Duration = .seconds(8)) -> SidecarClient {
        SidecarClient(socketPath: socketPath,
                      nodePath: SidecarClient.findNode(),
                      sidecarDir: tempDir.path,
                      requestTimeout: timeout)
    }

    func testFindNodeLocatesExecutable() {
        let node = SidecarClient.findNode()
        XCTAssertNotNil(node)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: node!))
    }

    func testPingRoundTrip() async throws {
        let client = makeClient()
        await client.start()
        let healthy = await client.isHealthy()
        XCTAssertTrue(healthy)
        await client.stop()
    }

    func testRefineRoundTrip() async throws {
        let client = makeClient()
        await client.start()
        let text = try await client.refine(
            transcript: "hello there", context: "ctx", appName: "TestApp")
        XCTAssertEqual(text, "FAKE-REFINED: hello there")
        await client.stop()
    }

    func testTimeoutWhenSidecarIsSlow() async throws {
        setenv("SKVOICE_FAKE_DELAY_MS", "3000", 1)
        defer { unsetenv("SKVOICE_FAKE_DELAY_MS") }
        let client = makeClient(timeout: .milliseconds(500))
        await client.start()
        do {
            _ = try await client.refine(transcript: "slow", context: "", appName: "")
            XCTFail("expected timeout")
        } catch let error as SidecarClient.ClientError {
            guard case .timeout = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
        }
        await client.stop()
    }

    func testRefineFailsCleanlyWithoutSidecarScript() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("skvoice-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let client = SidecarClient(
            socketPath: empty.appendingPathComponent("nope.sock").path,
            nodePath: SidecarClient.findNode(),
            sidecarDir: empty.path,
            requestTimeout: .milliseconds(400))
        await client.start()
        do {
            _ = try await client.refine(transcript: "x", context: "", appName: "")
            XCTFail("expected notConnected")
        } catch let error as SidecarClient.ClientError {
            guard case .notConnected = error else {
                return XCTFail("expected .notConnected, got \(error)")
            }
        }
        await client.stop()
    }
}
