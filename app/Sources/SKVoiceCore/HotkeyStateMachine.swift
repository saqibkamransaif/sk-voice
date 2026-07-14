import Foundation

/// Actions the hotkey pipeline must perform in response to modifier changes.
public enum HotkeyAction: Equatable, Sendable {
    case start(CaptureMode)
    /// A modifier pressed mid-hold upgraded the mode (sticky). Ctrl→refine, Shift→transform.
    case upgrade(CaptureMode)
    case finish(CaptureMode)
    /// Released before the hold threshold — discard the capture.
    case cancel
}

/// Pure state machine for hold-to-talk on Fn (dictation) / Fn+Ctrl (refine) /
/// Fn+Shift (transform). Feed it every flags snapshot; at most one action per transition.
/// Upgrades are sticky; Ctrl outranks Shift when both are held.
public struct HotkeyStateMachine: Sendable {
    private let holdThreshold: TimeInterval
    private var fnDown = false
    private var mode: CaptureMode = .dictation
    private var pressStart: TimeInterval = 0

    public init(holdThreshold: TimeInterval = 0.3) {
        self.holdThreshold = holdThreshold
    }

    public var isActive: Bool { fnDown }

    public mutating func handle(fn: Bool, ctrl: Bool, shift: Bool = false,
                                at t: TimeInterval) -> HotkeyAction? {
        if fn && !fnDown {
            fnDown = true
            pressStart = t
            mode = ctrl ? .refine : (shift ? .transform : .dictation)
            return .start(mode)
        }
        if fn && fnDown {
            if ctrl && mode != .refine {
                mode = .refine
                return .upgrade(.refine)
            }
            if shift && mode == .dictation {
                mode = .transform
                return .upgrade(.transform)
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
