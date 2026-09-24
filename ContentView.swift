import SwiftUI
import AppKit


struct ContentView: View {
    @ObservedObject var manager: PS5Manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    manager.isConnected
                        ? manager.controllerName
                        : "等待 DualSense 連線…",
                    systemImage: manager.isConnected
                        ? "gamecontroller.fill"
                        : "gamecontroller"
                )
                .foregroundStyle(
                    manager.isConnected ? Color.green : Color.secondary
                )
                Spacer()
                Label(batteryText, systemImage: batterySymbol)
                    .foregroundStyle(.secondary)
                    .help("手把電池電量")
            }

            Text("OSC：\(manager.targetIP):\(manager.targetPort)")
                .font(.caption)

            Text(manager.networkStatus)
                .font(.caption)
                .foregroundStyle(
                    manager.networkStatus.contains("拒絕")
                        || manager.networkStatus.contains("找不到")
                        || manager.networkStatus.contains("錯誤")
                        ? Color.red
                        : Color.secondary
                )

            Text("控制訊號最高 60 Hz · 已取樣 \(manager.framesSent) 次")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Link(
                "Designed by NeoLo",
                destination: URL(string: "https://github.com/KaedeKanio")!
            )

            Divider()

            Button("進階設定…") {
                openWindow(id: "settings")
            }

            Button("結束 DualSense OSC") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var batteryText: String {
        guard let batteryLevel = manager.batteryLevel else { return "--" }
        return "\(Int((batteryLevel * 100).rounded()))%"
    }

    private var batterySymbol: String {
        guard let batteryLevel = manager.batteryLevel else { return "battery.0percent" }
        switch batteryLevel {
        case ..<0.125: return "battery.0percent"
        case ..<0.375: return "battery.25percent"
        case ..<0.625: return "battery.50percent"
        case ..<0.875: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}


struct SettingsView: View {
    @ObservedObject var manager: PS5Manager

    var body: some View {
        Form {
            Section("OSC 目的地") {
                TextField("Target IP / 主機名稱", text: $manager.targetIP)
                TextField("UDP Port (1–65535)", text: $manager.targetPort)

                Text(manager.networkStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("搖桿") {
                deadzoneControl(
                    "左搖桿圓形死區",
                    value: $manager.deadzoneL
                )
                Toggle("反轉左 X", isOn: $manager.invertLX)
                Toggle("反轉左 Y", isOn: $manager.invertLY)

                deadzoneControl(
                    "右搖桿圓形死區",
                    value: $manager.deadzoneR
                )
                Toggle("反轉右 X", isOn: $manager.invertRX)
                Toggle("反轉右 Y", isOn: $manager.invertRY)
            }

            Section("體感軸向") {
                Toggle("反轉加速度計 X", isOn: $manager.invertAccelX)
                Toggle("反轉加速度計 Y", isOn: $manager.invertAccelY)
                Toggle("反轉加速度計 Z", isOn: $manager.invertAccelZ)

                Toggle("反轉陀螺儀 X", isOn: $manager.invertGyroX)
                Toggle("反轉陀螺儀 Y", isOn: $manager.invertGyroY)
                Toggle("反轉陀螺儀 Z", isOn: $manager.invertGyroZ)
            }

            Section("即時預覽") {
                Text("已送出 \(manager.framesSent) 幀")

                ForEach(manager.preview.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.caption)

                        Spacer()

                        Text(
                            String(
                                format: "%.3f",
                                manager.preview[key] ?? 0
                            )
                        )
                        .font(.system(.caption, design: .monospaced))
                    }
                }

                Text(
                    "PS 鍵與麥克風靜音鍵未由 GameController 穩定提供。控制訊號約 60 Hz；連線與電池狀態約 1 Hz。"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 420, minHeight: 650)
        .background(FloatingWindowConfigurator())
    }

    private func deadzoneControl(
        _ title: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)：\(value.wrappedValue, specifier: "%.2f")")
            Slider(value: value, in: 0...0.5)
        }
    }
}
