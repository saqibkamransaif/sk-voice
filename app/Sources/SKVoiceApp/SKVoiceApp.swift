import SwiftUI

@main
struct SKVoiceApp: App {
    var body: some Scene {
        MenuBarExtra("SK Voice", systemImage: "mic") {
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
