import Foundation
import AppKit
import ApplicationServices

/// Captures readable text from the frontmost window via the Accessibility tree —
/// no screenshots, no screen-recording permission. Best-effort: any failure returns
/// empty context and refine proceeds without it.
public enum ScreenContext {
    public static func capture(maxBytes: Int = 6144, budget: TimeInterval = 0.3)
        -> (appName: String, windowTitle: String, text: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName ?? ""
        guard AXIsProcessTrusted() else { return (appName, "", "") }

        let systemWide = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = attribute(systemWide, kAXFocusedApplicationAttribute),
              let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else {
            return (appName, "", "")
        }
        let windowTitle: String = attribute(window, kAXTitleAttribute) ?? ""

        let deadline = Date().addingTimeInterval(budget)
        var pieces: [String] = []
        var totalBytes = 0
        var queue: [AXUIElement] = [window]
        var visited = 0

        while !queue.isEmpty, totalBytes < maxBytes, Date() < deadline, visited < 800 {
            let element = queue.removeFirst()
            visited += 1

            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                guard let value: String = attribute(element, key),
                      !value.isEmpty, value.utf8.count < 4096 else { continue }
                pieces.append(value)
                totalBytes += value.utf8.count + 1
                if totalBytes >= maxBytes { break }
            }

            if let children: [AXUIElement] = attributeArray(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(64))
            }
        }

        var text = deduplicate(pieces).joined(separator: "\n")
        if text.utf8.count > maxBytes {
            text = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        }
        return (appName, windowTitle, text)
    }

    /// Consecutive duplicate strings (AX trees repeat titles/values) collapse to one.
    private static func deduplicate(_ pieces: [String]) -> [String] {
        var seen = Set<String>()
        return pieces.filter { seen.insert($0).inserted }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private static func attributeArray(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return nil }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }
}
