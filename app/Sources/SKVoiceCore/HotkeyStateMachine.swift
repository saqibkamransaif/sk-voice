import Foundation

/// Actions the hotkey pipeline must perform in response to modifier changes.
public enum HotkeyAction: Equatable, Sendable {
    case start(CaptureMode)
    /// Ctrl pressed while a dictation hold is active — mode becomes refine (sticky).
    case upgradeToRefine
    case finish(CaptureMode)
    /// Released before the hold threshold — discard the capture.
    case cancel
}

/// Pure state machine for hold-to-talk on Fn (dictation) / Fn+Ctrl (refine).
/// Feed it every flags snapshot; it emits at most one action per transition.
public struct HotkeyStateMachine: Sendable {
    private let holdThreshold: TimeInterval
    private var fnDown = false
    private var mode: CaptureMode = .dictation
    private var pressStart: TimeInterval = 0

    public init(holdThreshold: TimeInterval = 0.3) {
        self.holdThreshold = holdThreshold
    }

    public var isActive: Bool { fnDown }

    public mutating func handle(fn: Bool, ctrl: Bool, at t: TimeInterval) -> HotkeyAction? {
        if fn && !fnDown {
            fnDown = true
            pressStart = t
            mode = ctrl ? .refine : .dictation
            return .start(mode)
        }
        if fn && fnDown {
            if ctrl && mode == .dictation {
                mode = .refine
                return .upgradeToRefine
            }
            return nil
        }
        if !fn && fnDown {
            fnDown = false
            return (t - pressStart) >= holdThreshold ? .finish(mode) : .cancel
        }
        return nil
    }
}
