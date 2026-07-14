import Foundation
import AppKit
import Carbon.HIToolbox

/// Grabs the currently selected text in the frontmost app by synthesizing Cmd+C,
/// preserving the user's clipboard. Returns "" when nothing is selected.
public enum SelectionGrabber {
    public static func grab(timeout: Duration = .milliseconds(500)) async -> String {
        let pasteboard = NSPasteboard.general
        let saved = TextInserter.savedContents(of: pasteboard)
        let baseline = pasteboard.changeCount

        synthesizeCmdC()

        // Wait for the frontmost app to service the copy (changeCount bumps).
        var selection = ""
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if pasteboard.changeCount != baseline {
                selection = pasteboard.string(forType: .string) ?? ""
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Put the user's clipboard back regardless of outcome.
        TextInserter.restore(saved, to: pasteboard)
        return selection
    }

    private static func synthesizeCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
