import SwiftUI

@main
struct DualSenseTDApp: App {
    // 把核心大腦放在最上層，讓選單列和設定視窗共用同一個實體
    @StateObject private var manager = PS5Manager()

    var body: some Scene {
        // 1. 右上角選單列
        MenuBarExtra("DualSenseTD", systemImage: "gamecontroller") {
            ContentView(manager: manager)
        }
        .menuBarExtraStyle(.window)
        
        // 2. 獨立的進階設定視窗
        Window("進階設定 (DualSenseTD Settings)", id: "settings") {
            SettingsView(manager: manager)
        }
        // 限制視窗不能亂拉大小，保持介面整潔
        .windowResizability(.contentSize)
    }
}
