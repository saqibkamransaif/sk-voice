import Foundation
import AppKit
import Carbon.HIToolbox

public enum InsertResult: Equatable, Sendable {
    /// Text was pasted into the frontmost app; clipboard will be restored.
    case pasted
    /// Secure input was active (password field etc.) — text left on the clipboard.
    case copiedOnly
}

/// Pastes text at the cursor of the frontmost app by synthesizing Cmd+V, preserving
/// whatever was on the clipboard before.
public struct TextInserter {
    /// Injectable for tests; production uses the real secure-input check.
    public static func insert(
        _ text: String,
        isSecureInput: Bool = IsSecureEventInputEnabled(),
        restoreDelay: Duration = .milliseconds(300)
    ) async -> InsertResult {
        let pasteboard = NSPasteboard.general
        let saved = savedContents(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        guard !isSecureInput else {
            // Don't synthesize keystrokes into password fields; the text stays on the
            // clipboard for the user to paste deliberately. No restore.
            return .copiedOnly
        }

        synthesizeCmdV()

        // Give the target app time to read the pasteboard, then put the old contents back —
        // but only if nothing else wrote to the pasteboard in the meantime.
        try? await Task.sleep(for: restoreDelay)
        if pasteboard.changeCount == ourChangeCount {
            restore(saved, to: pasteboard)
        }
        return .pasted
    }

    // MARK: - Internals (internal for unit testing)

    static func savedContents(of pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType: Data] {
        var saved: [NSPasteboard.PasteboardType: Data] = [:]
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) {
                saved[type] = data
            }
        }
        return saved
    }

    static func restore(_ saved: [NSPasteboard.PasteboardType: Data],
                        to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for (type, data) in saved {
            pasteboard.setData(data, forType: type)
        }
    }

    private static func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
