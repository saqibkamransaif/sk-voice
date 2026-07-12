import Foundation

/// Which hotkey flow produced a capture.
public enum CaptureMode: String, Codable, Sendable, Equatable {
    case dictation
    case refine
}

/// One completed capture, persisted to history.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let mode: CaptureMode
    public let rawTranscript: String
    public let finalText: String
    public let appName: String
    public let durationSeconds: Double
    public let createdAt: Date

    public init(id: String = UUID().uuidString, mode: CaptureMode, rawTranscript: String,
                finalText: String, appName: String, durationSeconds: Double,
                createdAt: Date = Date()) {
        self.id = id
        self.mode = mode
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.appName = appName
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

/// A single vocabulary replacement rule (whole-word, case-insensitive match).
public struct VocabRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var find: String
    public var replace: String

    public init(id: String = UUID().uuidString, find: String, replace: String) {
        self.id = id
        self.find = find
        self.replace = replace
    }
}

/// User-configurable settings, JSON-persisted in Application Support.
public struct AppSettings: Codable, Sendable, Equatable {
    public var holdThreshold: Double
    public var refineSystemPrompt: String
    /// nil = subscription default model; otherwise a model alias like "haiku".
    public var modelOverride: String?
    public var vocabulary: [VocabRule]
    public var hotkeysPaused: Bool

    public static let defaultRefinePrompt = """
    You draft polished messages from dictated intent. The user dictates roughly what they \
    want to say; you produce the actual message, ready to send. Match the tone and formality \
    of the conversation context when provided (e.g. casual for chat apps, professional for \
    email). Keep the user's meaning exactly — do not add new facts, promises, or commitments. \
    Be concise. Output ONLY the message text: no preamble, no quotes, no explanations, no \
    markdown fences.
    """

    public init(holdThreshold: Double = 0.3,
                refineSystemPrompt: String = AppSettings.defaultRefinePrompt,
                modelOverride: String? = nil,
                vocabulary: [VocabRule] = [],
                hotkeysPaused: Bool = false) {
        self.holdThreshold = holdThreshold
        self.refineSystemPrompt = refineSystemPrompt
        self.modelOverride = modelOverride
        self.vocabulary = vocabulary
        self.hotkeysPaused = hotkeysPaused
    }

    // MARK: - Persistence

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SKVoice", isDirectory: true)
    }

    public static var settingsURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static func load(from url: URL = AppSettings.settingsURL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(to url: URL = AppSettings.settingsURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
