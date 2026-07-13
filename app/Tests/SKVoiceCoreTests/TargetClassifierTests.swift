import XCTest
@testable import SKVoiceCore

final class TargetClassifierTests: XCTestCase {
    func testMessagingAppsAreMessageMode() {
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            windowTitle: "#general"), .message)
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.apple.MobileSMS", appName: "Messages",
            windowTitle: "John"), .message)
    }

    func testAIDesktopAppsArePromptMode() {
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
            windowTitle: "New chat"), .prompt)
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.openai.chat", appName: "ChatGPT",
            windowTitle: ""), .prompt)
    }

    func testTerminalsArePromptMode() {
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.apple.Terminal", appName: "Terminal",
            windowTitle: "claude — 80x24"), .prompt)
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.googlecode.iterm2", appName: "iTerm2",
            windowTitle: "zsh"), .prompt)
    }

    func testBrowserTabTitleDetectsAI() {
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: "Claude — brainstorm ideas"), .prompt)
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: "ChatGPT"), .prompt)
    }

    func testBrowserWithoutAITitleIsMessage() {
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: "Inbox — Gmail"), .message)
    }

    func testMessagingBeatsAITitleMention() {
        // A Slack thread discussing Claude is still a message to humans.
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            windowTitle: "claude rollout — #ai-team"), .message)
    }

    func testUnknownDefaultsToMessage() {
        XCTAssertEqual(TargetClassifier.classify(
            bundleID: "com.random.app", appName: "RandomApp",
            windowTitle: "Untitled"), .message)
    }
}
