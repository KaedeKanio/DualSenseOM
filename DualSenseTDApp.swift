import SwiftUI

@main
struct DualSenseTDApp: App {
    var body: some Scene {
        // MenuBarExtra 會讓 App 直接長在右上角的系統選單列
        MenuBarExtra("DualSenseTD", systemImage: "gamecontroller") {
            ContentView()
        }
        .menuBarExtraStyle(.window) // 點擊圖示會彈出我們寫好的操作面板
    }
}
