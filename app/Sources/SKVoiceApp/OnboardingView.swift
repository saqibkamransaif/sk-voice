import SwiftUI
import AVFoundation
import IOKit.hid
import ApplicationServices
import SKVoiceCore

/// First-launch permission walkthrough. Live-polls each permission and lets the user
/// jump to the right System Settings pane. Shown until all three are green.
struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var microphone = Permissions.microphoneGranted()
    @State private var accessibility = Permissions.accessibilityGranted()
    @State private var inputMonitoring = Permissions.inputMonitoringGranted()

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to SK Voice")
                .font(.title.bold())
            Text("Three permissions make dictation work everywhere. Grant each one; the checks update automatically.")
                .foregroundStyle(.secondary)

            PermissionRow(
                title: "Microphone",
                detail: "Records your voice while you hold Fn.",
                granted: microphone,
                action: {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    openSettings("Privacy_Microphone")
                })

            PermissionRow(
                title: "Accessibility",
                detail: "Pastes text into the app you're using and reads on-screen context for refine mode.",
                granted: accessibility,
                action: {
                    // kAXTrustedCheckOptionPrompt is a mutable C global (not concurrency-safe
                    // in Swift 6); the literal key string is stable API.
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                    openSettings("Privacy_Accessibility")
                })

            PermissionRow(
                title: "Input Monitoring",
                detail: "Detects the Fn key anywhere on the system.",
                granted: inputMonitoring,
                action: {
                    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                    openSettings("Privacy_ListenEvent")
                })

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("One more thing", systemImage: "keyboard")
                    .font(.headline)
                Text("Set **“Press 🌐 key to” → “Do Nothing”** in Keyboard settings, so Fn doesn't also open the emoji picker or Apple dictation.")
                    .font(.callout)
                Button("Open Keyboard Settings") {
                    NSWorkspace.shared.open(URL(
                        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }

            if microphone && accessibility && inputMonitoring {
                Label("All set — SK Voice is ready. Hold Fn and speak.",
                      systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        }
        .padding(28)
        .frame(width: 520)
        .onReceive(poll) { _ in
            microphone = Permissions.microphoneGranted()
            accessibility = Permissions.accessibilityGranted()
            inputMonitoring = Permissions.inputMonitoringGranted()
            coordinator.refreshPermissions()
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}
