import SwiftUI
import AppKit
import UserNotifications
import SKVoiceCore

@main
struct SKVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator,
                        openDashboard: appDelegate.openDashboard)
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String {
        switch appDelegate.coordinator.barState {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing, .refining: "waveform"
        case .error: "mic.slash"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator
    let openDashboard: () -> Void

    var body: some View {
        Button("Open Dashboard") { openDashboard() }
            .keyboardShortcut("d")
        Toggle("Pause Hotkeys", isOn: Binding(
            get: { coordinator.settings.hotkeysPaused },
            set: { newValue in
                coordinator.settings.hotkeysPaused = newValue
                coordinator.applySettingsChange()
            }))
        Divider()
        Text("Hold Fn to dictate · Fn+Ctrl to refine")
        Divider()
        Button("Quit SK Voice") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator = AppCoordinator()
    private var floatingBar: FloatingBarController?
    private var dashboard: NSWindow?
    private var onboarding: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }

        // Register as a login item once, automatically; the Settings toggle still
        // lets the user turn it off without this fighting their choice on relaunch.
        let autoEnabledKey = "didAutoEnableLoginItem"
        if !UserDefaults.standard.bool(forKey: autoEnabledKey) {
            LoginItem.setEnabled(true)
            UserDefaults.standard.set(true, forKey: autoEnabledKey)
        }

        if coordinator.permissionsComplete {
            coordinator.startServices()
        } else {
            openOnboarding()
        }

        let bar = FloatingBarController(coordinator: coordinator) { [weak self] in
            self?.openDashboard()
        }
        bar.show()
        floatingBar = bar
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    func openDashboard() {
        if dashboard == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "SK Voice"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: DashboardView(coordinator: coordinator))
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openOnboarding() {
        if onboarding == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "SK Voice Setup"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: OnboardingView(coordinator: coordinator))
            onboarding = window
        }
        onboarding?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
