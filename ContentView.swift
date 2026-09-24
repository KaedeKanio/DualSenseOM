import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var manager: PS5Manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            controllerCard
            networkCard
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Label("OSC · 60 Hz", systemImage: "waveform.path")
                    Spacer(minLength: 4)
                    Label(manager.midiStatus, systemImage: "pianokeys")
                        .foregroundStyle(manager.midiEnabled && manager.midiAvailable ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Text("MIDI 埠：\(manager.midiSourceName)")
                    Spacer(minLength: 4)
                    Text("取樣 \(manager.sampledFrames.formatted()) 次").monospacedDigit()
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)

            Button { openWindow(id: "settings") } label: {
                Label("進階設定", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            HStack {
                Link(destination: URL(string: "https://github.com/KaedeKanio")!) {
                    Label("NeoLo", systemImage: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("結束") {
                    manager.prepareForExit()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [.cyan.opacity(0.9), .blue.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("DualSenseOM").font(.system(size: 15, weight: .bold))
                Text("CONTROLLER → TOUCHDESIGNER")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v0.1.1")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    private var controllerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(manager.isConnected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                Circle().fill(manager.isConnected ? Color.green : Color.secondary.opacity(0.6)).frame(width: 9, height: 9)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.isConnected ? "控制器已連線" : "等待控制器連線")
                    .font(.system(size: 13, weight: .semibold))
                Text(manager.isConnected ? manager.controllerName : "請確認 DualSense 已配對並喚醒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Label(batteryText, systemImage: batterySymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(manager.batteryLevel == nil ? Color.secondary : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.08)))
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("OSC 目的地", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("UDP").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(.cyan)
            }
            Text("\(manager.targetIP):\(manager.targetPort)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: networkSymbol).font(.caption2).padding(.top, 2)
                Text(manager.networkStatus).font(.caption2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(networkSymbol == "exclamationmark.triangle.fill" ? Color.orange : Color.secondary)
        }
        .padding(13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var batteryText: String {
        guard let level = manager.batteryLevel else { return "--" }
        return "\(Int((level * 100).rounded()))%"
    }

    private var batterySymbol: String {
        guard let level = manager.batteryLevel else { return "battery.0percent" }
        switch level {
        case ..<0.125: return "battery.0percent"
        case ..<0.375: return "battery.25percent"
        case ..<0.625: return "battery.50percent"
        case ..<0.875: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var networkSymbol: String {
        if manager.networkStatus.contains("錯誤") || manager.networkStatus.contains("拒絕") || manager.networkStatus.contains("找不到") || manager.networkStatus.contains("有效") {
            return "exclamationmark.triangle.fill"
        }
        if manager.networkStatus.contains("就緒") { return "checkmark.circle.fill" }
        return "clock"
    }
}

struct SettingsView: View {
    @ObservedObject var manager: PS5Manager
    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("設定").font(.system(size: 23, weight: .bold))
                        Text("調整 OSC 輸出與控制器訊號").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("v0.1.1").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }

                SettingsCard(title: "OSC 目的地", subtitle: "TouchDesigner 接收端", symbol: "dot.radiowaves.left.and.right") {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("TARGET IP").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                            TextField("127.0.0.1", text: $manager.targetIP).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PORT").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                            TextField("9999", text: $manager.targetPort).textFieldStyle(.roundedBorder).frame(width: 92)
                        }
                    }
                    Label(manager.networkStatus, systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("本機 TouchDesigner 使用 127.0.0.1；遠端接收請填入接收端 IP。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                SettingsCard(title: "MIDI 輸出", subtitle: "本機虛擬 MIDI 裝置", symbol: "pianokeys") {
                    Toggle("啟用 MIDI 輸出", isOn: $manager.midiEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("輸出加速度計／陀螺儀 MIDI", isOn: $manager.midiMotionEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(!manager.midiEnabled)
                    Text("預設關閉，避免 Arena 的 Shortcut Learn 被持續變動的體感訊號搶先捕捉。OSC 體感仍會照常輸出；關閉此項時，先前送出的體感軸會回到中心值。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Label(
                        manager.midiAvailable ? "\(manager.midiSourceName) · \(manager.midiStatus)" : "CoreMIDI 虛擬輸出 \(manager.midiStatus)",
                        systemImage: manager.midiAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption2).foregroundStyle(manager.midiAvailable ? Color.secondary : Color.orange)
                    Text("本次啟動已送出 \(manager.midiFramesSent.formatted()) 個完整控制器影格。")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    Text("TouchDesigner 請選「\(manager.midiSourceName)」（每影格完整狀態）；Arena 和 Ableton 請選「\(manager.midiLearnSourceName)」（只在數值改變時送出），避免 Shortcut Learn 一直被閒置 CC 觸發。兩個來源都由同一支手把控制。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Label(
                        "Learn 埠：\(manager.midiLearnStatus)",
                        systemImage: manager.midiLearnAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption2).foregroundStyle(manager.midiLearnAvailable ? Color.secondary : Color.orange)
                    Text("固定 CC 對照：16–19 搖桿、20–21 L2/R2、22–25 觸控座標、26–28 加速度、29–31 陀螺儀（體感 MIDI 開啟時輸出）、32–48 按鍵與觸控狀態。按鍵按下為 127、放開為 0；觸控座標放開歸零。每次取樣都送出目前啟用的完整狀態，避免未動的控制項消失。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arena：偏好設定 → MIDI，啟用 DualSenseOM MIDI Learn，再進入 MIDI Shortcuts 模式指派控制項。")
                        Text("Ableton Live：Settings → Link, Tempo & MIDI，輸入選 DualSenseOM MIDI Learn；開啟 Track 接收，映射 Live 參數時開 Remote。")
                    }
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Link("Arena 指南", destination: URL(string: "https://resolume.com/support/en/midi-shortcuts")!)
                        Link("Ableton MIDI 設定", destination: URL(string: "https://help.ableton.com/hc/en-us/articles/209774205-Live-s-MIDI-Settings")!)
                    }
                    .font(.caption2)
                }

                SettingsCard(title: "搖桿", subtitle: "圓形死區與軸向反轉", symbol: "circle.dotted") {
                    HStack(spacing: 15) {
                        deadzoneControl("左搖桿", value: $manager.deadzoneL)
                        deadzoneControl("右搖桿", value: $manager.deadzoneR)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        Toggle("反轉左 X", isOn: $manager.invertLX)
                        Toggle("反轉左 Y", isOn: $manager.invertLY)
                        Toggle("反轉右 X", isOn: $manager.invertRX)
                        Toggle("反轉右 Y", isOn: $manager.invertRY)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }

                SettingsCard(title: "體感軸向", subtitle: "加速度計與陀螺儀", symbol: "gyroscope") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        Toggle("反轉加速度計 X", isOn: $manager.invertAccelX)
                        Toggle("反轉加速度計 Y", isOn: $manager.invertAccelY)
                        Toggle("反轉加速度計 Z", isOn: $manager.invertAccelZ)
                        Toggle("反轉陀螺儀 X", isOn: $manager.invertGyroX)
                        Toggle("反轉陀螺儀 Y", isOn: $manager.invertGyroY)
                        Toggle("反轉陀螺儀 Z", isOn: $manager.invertGyroZ)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }

                SettingsCard(title: "即時訊號", subtitle: "畫面預覽約 10 Hz；OSC 控制訊號最高 60 Hz", symbol: "waveform.path") {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(manager.preview.keys.sorted(), id: \.self) { key in
                            HStack(spacing: 6) {
                                Circle().fill(signalColor(for: key)).frame(width: 5, height: 5)
                                Text(key).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                Spacer(minLength: 2)
                                Text(String(format: "%.3f", manager.preview[key] ?? 0))
                                    .font(.system(size: 10, design: .monospaced).weight(.medium)).monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    HStack {
                        Label("已取樣", systemImage: "checkmark.circle")
                        Spacer()
                        Text("\(manager.sampledFrames.formatted()) 次").monospacedDigit()
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    Text("PS 鍵與麥克風靜音鍵未由 GameController 穩定提供。觸控狀態由觸點座標判定。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Link("Designed by NeoLo", destination: URL(string: "https://github.com/KaedeKanio")!)
                    Spacer()
                    Text("OSC paths: /ds/c · /ds/s").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .font(.caption).padding(.horizontal, 2)
            }
            .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 500, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(FloatingWindowConfigurator())
    }

    private func deadzoneControl(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...0.5)
            Text("圓形範圍").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func signalColor(for key: String) -> Color {
        if key == "s/connected" { return manager.isConnected ? .green : .secondary }
        if key.hasPrefix("s/") { return .orange }
        if key.contains("touch") || key.contains("l1") || key.contains("r1") || key.contains("cross") || key.contains("circle") || key.contains("square") || key.contains("triangle") { return .purple }
        return .cyan
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.08)))
    }
}
