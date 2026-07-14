import Foundation

/// Schedules and prepares adaptive style learning: every N accepted refines, recent
/// (raw dictation → final sent) pairs go to the sidecar's `learn` turn, which maintains
/// a compact style profile that rides along on future refines.
public enum StyleLearner {
    /// Learn after every this-many accepted refines.
    public static let interval = 10

    public static func shouldLearn(insertCount: Int) -> Bool {
        insertCount > 0 && insertCount.isMultiple(of: interval)
    }

    /// Extracts usable training pairs from history entries (newest first).
    /// Only refine entries where the user's final text actually differs from the raw
    /// dictation carry a style signal.
    public static func pairs(from entries: [HistoryEntry], limit: Int = 10) -> [StylePair] {
        entries
            .filter {
                $0.mode == .refine
                    && !$0.rawTranscript.isEmpty
                    && !$0.finalText.isEmpty
                    && $0.rawTranscript != $0.finalText
            }
            .prefix(limit)
            .map { StylePair(raw: $0.rawTranscript, final: $0.finalText) }
    }
}
