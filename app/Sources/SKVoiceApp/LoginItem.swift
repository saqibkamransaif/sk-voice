import Foundation
import ServiceManagement
import SwiftUI

/// "Launch SK Voice at login" via SMAppService (macOS 13+). Same pattern as SK Note Taker.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            FileHandle.standardError.write(
                Data("SKVoice: login item toggle failed: \(error)\n".utf8))
            return false
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = LoginItem.isEnabled

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { enabled },
            set: { newValue in
                if LoginItem.setEnabled(newValue) { enabled = newValue }
            }))
    }
}
