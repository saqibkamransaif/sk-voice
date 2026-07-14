import Foundation
import CoreGraphics
import AppKit

/// Listens for Fn / Fn+Ctrl globally via a listen-only CGEventTap on flagsChanged and
/// drives the HotkeyStateMachine. Requires Input Monitoring (tap) permission.
public final class HotkeyMonitor: @unchecked Sendable {
    private let onAction: @Sendable (HotkeyAction) -> Void
    private var stateMachine: HotkeyStateMachine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let queue = DispatchQueue(label: "skvoice.hotkey")
    public var isPaused = false

    public init(holdThreshold: TimeInterval = 0.3,
                onAction: @escaping @Sendable (HotkeyAction) -> Void) {
        self.onAction = onAction
        self.stateMachine = HotkeyStateMachine(holdThreshold: holdThreshold)
    }

    public func updateThreshold(_ threshold: TimeInterval) {
        queue.sync {
            stateMachine = HotkeyStateMachine(holdThreshold: threshold)
        }
    }

    /// Returns false when the event tap could not be created (missing permission).
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPointer = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer) else {
            Unmanaged<HotkeyMonitor>.fromOpaque(selfPointer).release()
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            Unmanaged.passUnretained(self).release() // balance passRetained in start()
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables taps that stall; re-enable immediately.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged, !isPaused else { return }

        let flags = event.flags
        let fn = flags.contains(.maskSecondaryFn)
        let ctrl = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let time = ProcessInfo.processInfo.systemUptime

        let action = queue.sync {
            stateMachine.handle(fn: fn, ctrl: ctrl, shift: shift, at: time)
        }
        if let action {
            onAction(action)
        }
    }
}
