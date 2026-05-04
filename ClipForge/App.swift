import SwiftUI

@main
struct ClipForgeApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ProjectView()
                .environmentObject(settings)
                .frame(minWidth: 720, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
