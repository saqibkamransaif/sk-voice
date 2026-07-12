import Foundation

/// Applies user vocabulary rules to a transcript: case-insensitive, whole-word/phrase,
/// longest rule first so "note taker" beats "note".
public struct VocabularyProcessor: Sendable {
    private struct Compiled {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let compiled: [Compiled]

    public init(rules: [VocabRule]) {
        compiled = rules
            .filter { !$0.find.isEmpty }
            .sorted { $0.find.count > $1.find.count }
            .compactMap { rule in
                // \b only exists at word-char edges; non-word edges (e.g. "c++") get
                // lookarounds so adjacent punctuation/whitespace still delimits a match.
                let escaped = NSRegularExpression.escapedPattern(for: rule.find)
                let leading = rule.find.first!.isLetter || rule.find.first!.isNumber
                    ? "\\b" : "(?<!\\w)"
                let trailing = rule.find.last!.isLetter || rule.find.last!.isNumber
                    ? "\\b" : "(?!\\w)"
                guard let regex = try? NSRegularExpression(
                    pattern: leading + escaped + trailing,
                    options: [.caseInsensitive]) else { return nil }
                return Compiled(
                    regex: regex,
                    replacement: NSRegularExpression.escapedTemplate(for: rule.replace))
            }
    }

    public func apply(_ text: String) -> String {
        // Single pass over the ORIGINAL text: higher-priority (longer) rules claim their
        // ranges first, so lower-priority rules can't re-match inside replaced output.
        let full = NSRange(text.startIndex..., in: text)
        var claimed: [NSRange] = []
        var edits: [(range: NSRange, replacement: String)] = []
        let ns = text as NSString

        for rule in compiled {
            rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range,
                      !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 })
                else { return }
                claimed.append(range)
                let matched = ns.substring(with: range)
                let replaced = rule.regex.stringByReplacingMatches(
                    in: matched, range: NSRange(location: 0, length: matched.utf16.count),
                    withTemplate: rule.replacement)
                edits.append((range, replaced))
            }
        }

        var result = text
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(edit.range, in: result) else { continue }
            result.replaceSubrange(range, with: edit.replacement)
        }
        return result
    }
}
