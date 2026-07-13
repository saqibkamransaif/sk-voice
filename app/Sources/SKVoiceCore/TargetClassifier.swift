import Foundation

/// Whether a refine request targets a person (message) or an AI assistant (prompt).
public enum RefineMode: String, Codable, Sendable, Equatable {
    case message
    case prompt
}

/// Classifies the frontmost app as an AI-prompting surface or a human-messaging surface.
/// Deterministic and instant (bundle id + app name + window title heuristics); the review
/// window lets the user flip the badge when the guess is wrong.
public enum TargetClassifier {
    /// Bundle-id fragments that are AI assistants or AI-first editors.
    private static let aiBundleFragments = [
        "com.anthropic",           // Claude desktop
        "com.openai",              // ChatGPT desktop
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.warp.Warp",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
    ]

    /// Title/context markers that indicate an AI chat surface inside a generic app (browser tabs).
    private static let aiTitleMarkers = [
        "claude", "chatgpt", "gemini", "copilot", "perplexity", "grok",
    ]

    /// App names that are always human messaging, even if the window title mentions AI.
    private static let messagingNames = [
        "messages", "slack", "mail", "outlook", "whatsapp", "telegram", "discord",
        "signal", "teams", "linkedin", "messenger", "instagram",
    ]

    public static func classify(bundleID: String?, appName: String,
                                windowTitle: String) -> RefineMode {
        let name = appName.lowercased()
        if messagingNames.contains(where: { name.contains($0) }) {
            return .message
        }
        if let bundleID, aiBundleFragments.contains(where: { bundleID.hasPrefix($0) || bundleID.contains($0) }) {
            return .prompt
        }
        let title = windowTitle.lowercased()
        if aiTitleMarkers.contains(where: { title.contains($0) || name.contains($0) }) {
            return .prompt
        }
        return .message
    }
}
