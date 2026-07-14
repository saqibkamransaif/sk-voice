import Foundation

/// A voice snippet: a spoken trigger phrase expanded into a template.
public struct SnippetRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var trigger: String
    public var template: String

    public init(id: String = UUID().uuidString, trigger: String, template: String) {
        self.id = id
        self.trigger = trigger
        self.template = template
    }
}

/// Deterministic transcript post-processing — spoken commands and snippets, zero LLM
/// latency. Runs after vocabulary rules, before delivery.
///
/// Commands: "new line" / "new paragraph" (inline), "scratch that" (drops everything
/// dictated before it; a capture that ends scratched returns nil).
public struct TranscriptPostProcessor: Sendable {
    private let snippets: [(regex: NSRegularExpression, template: String)]

    private static let scratch = try! NSRegularExpression(
        pattern: #"[.,!?]*\s*\bscratch that\b[.,!?]*\s*"#, options: [.caseInsensitive])
    private static let newParagraph = try! NSRegularExpression(
        pattern: #",?\s*\bnew paragraph\b[.,]?\s*"#, options: [.caseInsensitive])
    private static let newLine = try! NSRegularExpression(
        pattern: #",?\s*\bnew line\b[.,]?\s*"#, options: [.caseInsensitive])

    public init(snippets: [SnippetRule]) {
        self.snippets = snippets
            .filter { !$0.trigger.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
            .compactMap { rule in
                let escaped = NSRegularExpression.escapedPattern(for: rule.trigger)
                guard let regex = try? NSRegularExpression(
                    pattern: "\\b" + escaped + "\\b[.,!?]?",
                    options: [.caseInsensitive]) else { return nil }
                return (regex, rule.template)
            }
    }

    /// Returns the processed transcript, or nil when nothing remains to deliver.
    public func apply(_ text: String) -> String? {
        var result = text

        // 1. Scratch that — only what follows the LAST occurrence survives.
        let full = NSRange(result.startIndex..., in: result)
        if let last = Self.scratch.matches(in: result, range: full).last,
           let range = Range(last.range, in: result) {
            result = String(result[range.upperBound...])
        }

        // 2. Snippets (longest trigger first, template is literal).
        for snippet in snippets {
            result = snippet.regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.template))
        }

        // 3. Line-break commands.
        result = Self.newParagraph.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "\n\n")
        result = Self.newLine.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "\n")

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
