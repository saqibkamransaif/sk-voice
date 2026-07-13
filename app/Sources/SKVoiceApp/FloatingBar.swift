import SwiftUI
import AppKit
import SKVoiceCore

/// Screen-edge pill showing recording/processing state, pinned to the right edge like
/// Willow's bar. Non-activating panel: it never steals focus from the app being dictated into.
@MainActor
final class FloatingBarController {
    private var panel: NSPanel?
    private let coordinator: AppCoordinator
    private let onOpenDashboard: () -> Void

    init(coordinator: AppCoordinator, onOpenDashboard: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onOpenDashboard = onOpenDashboard
    }

    func show() {
        guard panel == nil else { return }
        let size = NSSize(width: 26, height: 96)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let view = FloatingBarView(coordinator: coordinator, onTap: onOpenDashboard)
        panel.contentView = NSHostingView(rootView: view)
        position(panel: panel)
        panel.orderFrontRegardless()
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let self, let panel = self.panel { self.position(panel: panel) }
            }
        }
    }

    private func position(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - panel.frame.width - 2
        let y = frame.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct FloatingBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    let onTap: () -> Void

    var body: some View {
        VStack {
            switch coordinator.barState {
            case .idle:
                Circle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 7, height: 7)
            case .recording(let mode):
                WaveformView(level: coordinator.inputLevel,
                             tint: mode == .refine ? .orange : .green)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.green)
            case .refining:
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 22, height: 88)
        .background(
            Capsule()
                .fill(.black.opacity(barOpacity))
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.15), value: coordinator.barState)
        .padding(2)
    }

    private var barOpacity: Double {
        if case .idle = coordinator.barState { return 0.25 }
        return 0.65
    }
}

/// Five bars scaled by mic level — cheap and instant-feeling.
struct WaveformView: View {
    let level: Float
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 4, height: barHeight(index))
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let boosted = min(1.0, CGFloat(level) * 18)
        let phase = CGFloat([0.6, 0.85, 1.0, 0.85, 0.6][index])
        return 4 + boosted * 10 * phase
    }
}
