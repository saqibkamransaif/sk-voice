import SwiftUI
import AppKit
import SKVoiceCore

/// One in-flight refine review: the draft being polished before insertion.
@MainActor
final class ReviewSession: ObservableObject {
    @Published var draft: String = ""
    @Published var mode: RefineMode
    @Published var busy = true
    @Published var busyLabel = "Drafting…"
    @Published var errorText: String?
    @Published var listening = false

    let rawTranscript: String
    let context: String
    let appName: String
    let targetApp: NSRunningApplication?
    /// Transform mode: rawTranscript is the spoken instruction, applied to the selection.
    let isTransform: Bool
    private(set) var originalSelection: String?

    init(rawTranscript: String, context: String, appName: String,
         mode: RefineMode, targetApp: NSRunningApplication?,
         isTransform: Bool = false) {
        self.rawTranscript = rawTranscript
        self.context = context
        self.appName = appName
        self.mode = mode
        self.targetApp = targetApp
        self.isTransform = isTransform
    }

    func rememberSelection(_ selection: String) {
        originalSelection = selection
    }
}

/// Floating panel hosting the review UI. Activating (the draft is editable),
/// but restores focus to the target app on insert.
@MainActor
final class ReviewWindowController {
    private var panel: NSPanel?

    func show(session: ReviewSession, coordinator: AppCoordinator) {
        close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.contentView = NSHostingView(rootView: ReviewView(
            session: session, coordinator: coordinator))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - 250,
                y: frame.midY + frame.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct ReviewView: View {
    @ObservedObject var session: ReviewSession
    let coordinator: AppCoordinator
    @FocusState private var editorFocused: Bool

    private var accent: Color {
        if session.isTransform { return .purple }
        return session.mode == .prompt ? .indigo : .teal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            if let error = session.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            chips
            footer
        }
        .padding(16)
        .frame(width: 500)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1))
        .onExitCommand { coordinator.discardReview() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if !session.isTransform { coordinator.switchReviewMode() }
            } label: {
                Label(session.isTransform ? "Rewrite"
                          : session.mode == .prompt ? "Prompt" : "Message",
                      systemImage: session.isTransform ? "wand.and.stars"
                          : session.mode == .prompt
                          ? "sparkles.rectangle.stack" : "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("Detected target — click to switch and re-draft")

            Text("→ \(session.appName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if session.listening {
                Label("Listening…", systemImage: "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative)
            } else if session.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(session.busyLabel).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Hold Fn to adjust by voice")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $session.draft)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 110, maxHeight: 220)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .focused($editorFocused)
            .disabled(session.busy)
            .opacity(session.busy ? 0.55 : 1)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(["Shorter", "More formal", "More casual", "More detailed"],
                    id: \.self) { chip in
                Button(chip) {
                    coordinator.reviseReview(instruction: chip.lowercased())
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .disabled(session.busy)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Discard") { coordinator.discardReview() }
                .keyboardShortcut(.cancelAction)
            Button {
                coordinator.regenerateReview()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session.busy)

            Spacer()

            Button {
                coordinator.insertReview()
            } label: {
                Label("Insert", systemImage: "return")
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(session.busy || session.draft.isEmpty)
        }
    }
}
