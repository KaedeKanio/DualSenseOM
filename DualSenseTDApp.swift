import SwiftUI

@main
struct DualSenseTDApp: App {
    @StateObject private var manager = PS5Manager()

    var body: some Scene {
        MenuBarExtra("DualSenseOM", systemImage: "gamecontroller") {
            ContentView(manager: manager)
        }
        .menuBarExtraStyle(.window)

        Window("進階設定", id: "settings") {
            SettingsView(manager: manager)
        }
        .windowResizability(.contentSize)
    }
}
