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
            Text("v0.2.0")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    private var controllerCard: some View {
        VStack(spacing: 7) {
            ForEach(manager.controllerStatuses) { status in
                HStack(spacing: 10) {
                    Circle()
                        .fill(status.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("手把 \(status.slot) · \(status.isConnected ? "已連線" : "等待連線")")
                            .font(.system(size: 12, weight: .semibold))
                        Text(status.isConnected ? status.name : "請確認 DualSense 已配對並喚醒")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Label("\(batteryText(status.batteryLevel)) · \(status.batteryState?.title ?? "未知")", systemImage: batterySymbol(status.batteryLevel))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(status.batteryState == .charging ? Color.green : (status.batteryLevel == nil ? Color.secondary : Color.primary))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
            }
            HStack(spacing: 6) {
                Image(systemName: manager.hidTriggerStatus.contains("就緒") ? "checkmark.circle.fill" : "link")
                    .foregroundStyle(manager.hidTriggerStatus.contains("就緒") ? Color.green : Color.secondary)
                Text(manager.hidTriggerStatus)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.top, 1)
        }
        .padding(4)
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
            ForEach(1...2, id: \.self) { slot in
                let outPort = slot == 1 ? manager.targetPort1 : manager.targetPort2
                let inPort = slot == 1 ? manager.oscReceivePort1 : manager.oscReceivePort2
                let outStatus = slot == 1 ? manager.networkStatus1 : manager.networkStatus2
                let inStatus = slot == 1 ? manager.oscReceiveStatus1 : manager.oscReceiveStatus2
                VStack(alignment: .leading, spacing: 3) {
                    Text("手把 \(slot) · 輸出 \(manager.targetIP):\(outPort) · 接收 \(inPort)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text("↑ \(outStatus)   ↓ \(inStatus)")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                }
                .textSelection(.enabled)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private func batteryText(_ level: Float?) -> String {
        guard let level else { return "--" }
        return "\(Int((level * 100).rounded()))%"
    }

    private func batterySymbol(_ level: Float?) -> String {
        guard let level else { return "battery.0percent" }
        switch level {
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
                    Text("v0.2.0").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }

                SettingsCard(title: "OSC 網路", subtitle: "控制器輸出與燈色回傳", symbol: "dot.radiowaves.left.and.right") {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("TARGET IP").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                            TextField("127.0.0.1", text: $manager.targetIP).textFieldStyle(.roundedBorder)
                        }
                    }
                    Text("OSC OUT · 兩支手把分別送到 TouchDesigner 的不同接收埠")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("手把 1 · OUT PORT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            TextField("9991", text: $manager.targetPort1).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("手把 2 · OUT PORT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            TextField("9992", text: $manager.targetPort2).textFieldStyle(.roundedBorder)
                        }
                    }
                    Text("OSC IN · 從 TouchDesigner 接收各手把燈色")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("手把 1 · IN PORT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            TextField("9993", text: $manager.oscReceivePort1).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("手把 2 · IN PORT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            TextField("9994", text: $manager.oscReceivePort2).textFieldStyle(.roundedBorder)
                        }
                    }
                    Text("輸出：手把 1/2 使用不同目的埠，因此 TouchDesigner 請建立兩個 OSC In CHOP，分別監聽 9991/9992。兩個埠內的 OSC 位址相同（例如 /ds/c/lx），由埠號區分手把。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Text("燈色不需寫程式：建立兩個 OSC Out CHOP，分別送到 127.0.0.1:\(manager.oscReceivePort1) 和 127.0.0.1:\(manager.oscReceivePort2)。每個 CHOP 使用 /led/r、/led/g、/led/b 三個 RGB 通道；將相同 RGB 值接到畫面和對應輸出。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Text("傳入埠使用 9993/9994，刻意與 TouchDesigner 的輸出接收埠 9991/9992 分開，避免同一台 Mac 上埠號衝突。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard(title: "控制器、燈色與震動", subtitle: "最多兩支 DualSense；路由可重新指定", symbol: "lightbulb") {
                    ForEach(manager.controllerStatuses) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(status.isConnected ? Color.green : Color.secondary.opacity(0.45))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("手把 \(status.slot)").font(.caption.weight(.semibold))
                                    Text(controllerLightDescription(status))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ColorPicker("LED 顏色", selection: colorBinding(for: status.slot), supportsOpacity: false)
                                    .labelsHidden()
                                    .disabled(status.isConnected && status.supportsLight == false)
                            }
                            HStack {
                                Text(controllerHapticsDescription(status))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    manager.playHapticTest(slot: status.slot)
                                } label: {
                                    Label("短震測試", systemImage: "waveform")
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(status.supportsHaptics != true)
                                Button {
                                    manager.playGripHapticTest(slot: status.slot)
                                } label: {
                                    Label("連續震動測試", systemImage: "waveform.path")
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(status.supportsHaptics != true || !manager.hapticsOSCEnabled)
                                Menu("指定至") {
                                    Button("手把 1") { manager.assignController(fromSlot: status.slot, toSlot: 1) }
                                        .disabled(!status.isConnected || status.slot == 1)
                                    Button("手把 2") { manager.assignController(fromSlot: status.slot, toSlot: 2) }
                                        .disabled(!status.isConnected || status.slot == 2)
                                }
                                .menuStyle(.borderlessButton)
                                .disabled(!status.isConnected)
                            }
                            HStack(spacing: 8) {
                                Button("L2 扳機測試") { manager.playAdaptiveTriggerTest(slot: status.slot, side: "l2") }
                                Button("R2 扳機測試") { manager.playAdaptiveTriggerTest(slot: status.slot, side: "r2") }
                                Button("解除扳機效果") {
                                    manager.stopAdaptiveTrigger(slot: status.slot, side: "l2")
                                    manager.stopAdaptiveTrigger(slot: status.slot, side: "r2")
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!status.isConnected)
                            ForEach(["l2", "r2"], id: \.self) { side in
                                adaptiveTriggerControls(slot: status.slot, side: side, connected: status.isConnected)
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Text("「指定至」會交換兩支已連線手把的編號，並同步更換 OSC／MIDI 路由。使用 GameController 玩家編號辨識；若 macOS 重新連線後回報不同，可再次指定。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Text("顏色會記憶並在手把連線時套用。若 GameController 沒有提供該手把的燈色功能，顏色選擇不會生效；Apple API 未提供燈區或閃爍模式的選項。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Text("連續震動使用 /haptic；短震使用 /haptic/pulse。兩者都作用於整支手把。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Toggle("接收 OSC 震動控制", isOn: $manager.hapticsOSCEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("/haptic：連續震動強度 0…1，送 0 停止。/haptic/pulse：短震強度 0…1；送 0 後才能再次觸發。")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            Text("/haptic — continuous\n/haptic/pulse — pulse")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer(minLength: 2)
                            Button("複製 Haptic 位址") {
                                copyAdvancedText("/haptic\n/haptic/pulse")
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                    Text("在 TouchDesigner 建立 OSC Out CHOP，目的 IP 設為這台 Mac；手把 1 送至 Port 9993，手把 2 送至 9994。Channel 名稱使用下列 OSC 位址，數值直接填 0…1：")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Trigger Mode 可用英文名稱設定。可送 OSC 字串到 /trigger/l2/mode；使用 OSC Out CHOP 時，改用下列 mode/名稱 位址，數值會忽略：")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            Text("/trigger/l2/start = 0.2\n/trigger/l2/end = 0.8\n/trigger/l2/strength = 0.65\n/trigger/l2/frequency = 128\n/trigger/l2/mode/none\n/trigger/l2/mode/trigger\n/trigger/l2/mode/weapon\n/trigger/l2/mode/vibration\n/trigger/l2/mode/bow\n/trigger/l2/mode/galloping\n/trigger/l2/mode/machine")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer(minLength: 2)
                            Button("複製 Trigger 設定") {
                                copyAdvancedText("/trigger/l2/start = 0.2\n/trigger/l2/end = 0.8\n/trigger/l2/strength = 0.65\n/trigger/l2/frequency = 128\n/trigger/l2/mode/none\n/trigger/l2/mode/trigger\n/trigger/l2/mode/weapon\n/trigger/l2/mode/vibration\n/trigger/l2/mode/bow\n/trigger/l2/mode/galloping\n/trigger/l2/mode/machine")
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                        }
                        Text("none＝關閉；trigger＝固定阻力；weapon＝武器阻力；vibration＝扳機震動；bow＝弓弦；galloping＝交替步進；machine＝連發。l2 換成 r2 控制另一側。Mode/名稱 位址適用 CHOP；也可送字串參數 trigger 到 /trigger/l2/mode。")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
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
                    Text("手把 1、2 是分開的虛擬 MIDI 裝置。TouchDesigner 完整輸出：\(manager.midiSourceName(slot: 1))、\(manager.midiSourceName(slot: 2))；Arena／Ableton Learn 輸出：\(manager.midiLearnSourceName(slot: 1))、\(manager.midiLearnSourceName(slot: 2))。沿用 Channel 1/2 與相同 CC 對照。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Label(
                        "Learn 埠：\(manager.midiLearnStatus)",
                        systemImage: manager.midiLearnAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption2).foregroundStyle(manager.midiLearnAvailable ? Color.secondary : Color.orange)
                    Text("固定 CC 對照：16–19 搖桿、20–21 L2/R2、22–25 觸控座標、26–28 加速度、29–31 陀螺儀（體感 MIDI 開啟時輸出）、32–48 按鍵與觸控狀態。按鍵按下為 127、放開為 0；兩支手把各用獨立 MIDI Channel。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arena：偏好設定 → MIDI，啟用對應手把的 DualSenseOM MIDI Learn 1 或 2，再進入 MIDI Shortcuts 指派。")
                        Text("Ableton Live：Settings → Link, Tempo & MIDI，分別啟用 DualSenseOM MIDI Learn 1/2；開啟 Track 接收，映射 Live 參數時開 Remote。")
                    }
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Link("Arena 指南", destination: URL(string: "https://resolume.com/support/en/midi-shortcuts")!)
                        Link("Ableton MIDI 設定", destination: URL(string: "https://help.ableton.com/hc/en-us/articles/209774205-Live-s-MIDI-Settings")!)
                    }
                    .font(.caption2)
                }

                ForEach(1...2, id: \.self) { slot in
                    SettingsCard(title: "手把 \(slot) 設定", subtitle: "搖桿與體感軸向各自設定", symbol: "gamecontroller") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("搖桿", systemImage: "circle.dotted").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 15) {
                            deadzoneControl("左搖桿", value: deadzoneBinding(slot: slot, stick: "left"))
                            deadzoneControl("右搖桿", value: deadzoneBinding(slot: slot, stick: "right"))
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            Toggle("反轉左 X", isOn: axisBinding(slot: slot, axis: "lx"))
                            Toggle("反轉左 Y", isOn: axisBinding(slot: slot, axis: "ly"))
                            Toggle("反轉右 X", isOn: axisBinding(slot: slot, axis: "rx"))
                            Toggle("反轉右 Y", isOn: axisBinding(slot: slot, axis: "ry"))
                        }
                        .toggleStyle(.switch).controlSize(.small)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                        Label("體感軸向", systemImage: "gyroscope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            Toggle("反轉加速度計 X", isOn: axisBinding(slot: slot, axis: "accelX"))
                            Toggle("反轉加速度計 Y", isOn: axisBinding(slot: slot, axis: "accelY"))
                            Toggle("反轉加速度計 Z", isOn: axisBinding(slot: slot, axis: "accelZ"))
                            Toggle("反轉陀螺儀 X", isOn: axisBinding(slot: slot, axis: "gyroX"))
                            Toggle("反轉陀螺儀 Y", isOn: axisBinding(slot: slot, axis: "gyroY"))
                            Toggle("反轉陀螺儀 Z", isOn: axisBinding(slot: slot, axis: "gyroZ"))
                        }
                        .toggleStyle(.switch).controlSize(.small)
                        }
                    }
                }

                SettingsCard(title: "額外體感 OSC", subtitle: "進階空間資料；預設關閉以控制訊號量", symbol: "rotate.3d") {
                    Toggle("輸出姿態、重力與使用者加速度", isOn: $manager.extendedMotionOSCEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("啟用後額外送出 /ds/c/attitude/x,y,z,w（四元數）、/ds/c/gravity/x,y,z（重力向量）、/ds/c/useracc/x,y,z（扣除重力後的加速度）。只走 OSC、不加入 MIDI；若手把沒有原生資料，會由陀螺儀與加速度計估算。估算姿態會累積漂移；重力低通估算不適合分離非常緩慢的移動。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    if manager.extendedMotionOSCEnabled {
                        ForEach(1...2, id: \.self) { slot in
                            Text(manager.extendedMotionDescription(slot: slot))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsCard(title: "即時訊號", subtitle: "畫面預覽約 10 Hz；OSC 控制訊號最高 60 Hz", symbol: "waveform.path") {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(1...2, id: \.self) { slot in
                            liveSignalColumn(slot: slot)
                        }
                    }
                    HStack(spacing: 10) {
                        signalLegend(.cyan, "類比／體感")
                        signalLegend(.purple, "按鍵／觸控")
                        signalLegend(.green, "連線")
                        signalLegend(.orange, "電池")
                    }
                    .font(.system(size: 9, weight: .medium))
                    HStack {
                        Label("已取樣", systemImage: "checkmark.circle")
                        Spacer()
                        Text("\(manager.sampledFrames.formatted()) 次").monospacedDigit()
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    Text("麥克風靜音鍵未出現在此控制器 profile。觸控狀態由觸點座標判定，GameController 未提供獨立的 DualSense 觸碰布林值。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Link("Designed by NeoLo", destination: URL(string: "https://github.com/KaedeKanio")!)
                    Spacer()
                    Text("OSC ports: \(manager.targetPort1) · \(manager.targetPort2)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .font(.caption).padding(.horizontal, 2)
            }
            .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 500, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(FloatingWindowConfigurator())
    }

    private func adaptiveTriggerControls(slot: Int, side: String, connected: Bool) -> some View {
        let settings = manager.adaptiveTriggerSettings(for: slot, side: side)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("手把 \(slot) · \(side.uppercased()) Adaptive Trigger")
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker("模式", selection: triggerBinding(slot: slot, side: side, parameter: "mode")) {
                    Text("none").tag(0.0)
                    Text("trigger").tag(1.0)
                    Text("weapon").tag(2.0)
                    Text("vibration").tag(3.0)
                    Text("bow").tag(4.0)
                    Text("galloping").tag(5.0)
                    Text("machine").tag(6.0)
                }
                .labelsHidden().frame(width: 125)
            }
            .disabled(!connected)
            if settings.mode != 0 {
                triggerParameterRow("Start", value: triggerBinding(slot: slot, side: side, parameter: "start"))
                triggerParameterRow("End", value: triggerBinding(slot: slot, side: side, parameter: "end"))
            }
            if [1, 2, 3, 4].contains(settings.mode) {
                triggerParameterRow(settings.mode == 4 ? "弓弦阻力" : "Strength", value: triggerBinding(slot: slot, side: side, parameter: "strength"))
            }
            if [4, 5, 6].contains(settings.mode) {
                triggerParameterRow(settings.mode == 4 ? "回彈強度" : "Strength 2", value: triggerBinding(slot: slot, side: side, parameter: "strength2"))
            }
            if [3, 5, 6].contains(settings.mode) {
                triggerParameterRow("Frequency", value: triggerBinding(slot: slot, side: side, parameter: "frequency"), range: 0...255, unit: "Hz")
            }
            if settings.mode == 6 {
                triggerParameterRow("Period", value: triggerBinding(slot: slot, side: side, parameter: "period"))
            }
            if settings.mode >= 4 {
                Text("此 HID 模式直接控制手把；OSC 參數：/trigger/\(side)/mode、start、end、strength、strength2、frequency、period。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .disabled(!connected)
    }

    private func triggerParameterRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, unit: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption2).frame(width: 76, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
            Slider(value: value, in: range, step: range.upperBound > 1 ? 1 : 0.01)
            AdaptiveTriggerNumberField(value: value, range: range)
                .frame(width: unit == nil ? 64 : 56, height: 25)
                .padding(.horizontal, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.11), lineWidth: 1))
            if let unit {
                Text(unit).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            }
        }
    }

    private func triggerBinding(slot: Int, side: String, parameter: String) -> Binding<Double> {
        Binding(
            get: {
                let settings = manager.adaptiveTriggerSettings(for: slot, side: side)
                switch parameter {
                case "mode": return Double(settings.mode)
                case "start": return Double(settings.start)
                case "end": return Double(settings.end)
                case "strength": return Double(settings.strength)
                case "strength2": return Double(settings.strength2)
                case "period": return Double(settings.period)
                default: return Double(settings.frequency) * 255
                }
            },
            set: { manager.setAdaptiveTriggerParameter(parameter, value: $0, slot: slot, side: side) }
        )
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

    private func deadzoneBinding(slot: Int, stick: String) -> Binding<Double> {
        Binding(
            get: { manager.deadzone(slot: slot, stick: stick) },
            set: { manager.setDeadzone($0, slot: slot, stick: stick) }
        )
    }

    private func axisBinding(slot: Int, axis: String) -> Binding<Bool> {
        Binding(
            get: { manager.isAxisInverted(slot: slot, axis: axis) },
            set: { manager.setAxisInverted($0, slot: slot, axis: axis) }
        )
    }

    private func colorBinding(for slot: Int) -> Binding<Color> {
        Binding(
            get: {
                let rgb = manager.controllerStatuses.first(where: { $0.slot == slot })?.lightColor
                    ?? RGBColor(red: 0.12, green: 0.56, blue: 0.96)
                return Color(red: Double(rgb.red), green: Double(rgb.green), blue: Double(rgb.blue))
            },
            set: { color in
                let resolved = (NSColor(color).usingColorSpace(.deviceRGB) ?? .white)
                manager.setLightColor(
                    RGBColor(red: Float(resolved.redComponent), green: Float(resolved.greenComponent), blue: Float(resolved.blueComponent)),
                    forSlot: slot
                )
            }
        )
    }

    private func controllerLightDescription(_ status: ControllerSlotStatus) -> String {
        guard status.isConnected else { return "未連線 · 顏色會在連線後套用" }
        if status.supportsLight == true { return "已連線 · 系統提供燈色控制" }
        if status.supportsLight == false { return "已連線 · 系統未提供燈色控制" }
        return "已連線 · 正在檢查燈色支援"
    }

    private func controllerHapticsDescription(_ status: ControllerSlotStatus) -> String {
        guard status.isConnected else { return "震動：等待連線" }
        return status.supportsHaptics == true ? "震動：系統可用" : "震動：系統未提供"
    }

    private func signalColor(for key: String) -> Color {
        if key == "s/connected" || key == "2/s/connected" {
            return (manager.preview[key] ?? 0) > 0 ? .green : .secondary
        }
        if key.hasPrefix("s/") || key.contains("/s/") { return .orange }
        if key.contains("touch") || key.contains("l1") || key.contains("r1") || key.contains("cross") || key.contains("circle") || key.contains("square") || key.contains("triangle") { return .purple }
        return .cyan
    }

    private func liveSignalColumn(slot: Int) -> some View {
        let status = manager.controllerStatuses.first(where: { $0.slot == slot })
        let prefix = slot == 1 ? "" : "2/"
        let extendedMotionNames: Set<String> = [
            "c/attitude/x", "c/attitude/y", "c/attitude/z", "c/attitude/w",
            "c/gravity/x", "c/gravity/y", "c/gravity/z",
            "c/useracc/x", "c/useracc/y", "c/useracc/z"
        ]
        let entries = manager.preview.keys.filter {
            ($0.hasPrefix(prefix + "c/") || $0.hasPrefix(prefix + "s/")) &&
            (manager.extendedMotionOSCEnabled || !extendedMotionNames.contains(displaySignalName($0, slot: slot)))
        }.sorted { a, b in
            let aStatus = a.contains("/s/") || a.hasPrefix("s/")
            let bStatus = b.contains("/s/") || b.hasPrefix("s/")
            if aStatus != bStatus { return aStatus }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(status?.isConnected == true ? .green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text("手把 \(slot)").font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Text(status?.isConnected == true ? "已連線" : "未連線")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(status?.isConnected == true ? .green : .secondary)
            }
            Text("\(batteryText(status?.batteryLevel)) · \(status?.batteryState?.title ?? "未知")")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(entries, id: \.self) { key in
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(signalColor(for: key)).frame(width: 5, height: 5)
                        Text(displaySignalName(key, slot: slot)).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 1)
                        Text(String(format: "%.3f", manager.preview[key] ?? 0))
                            .font(.system(size: 9, design: .monospaced).weight(.medium)).monospacedDigit()
                    }
                    if key.contains("/c/") || key.hasPrefix("c/") {
                        GeometryReader { geometry in
                            let signed = isSignedSignal(key, slot: slot)
                            let value = Double(manager.preview[key] ?? 0)
                            ZStack {
                                Capsule().fill(Color.primary.opacity(0.09))
                                if signed {
                                    let amount = geometry.size.width * 0.5 * min(abs(value), 1)
                                    Capsule().fill(signalColor(for: key))
                                        .frame(width: amount)
                                        .position(x: geometry.size.width * 0.5 + (value < 0 ? -amount * 0.5 : amount * 0.5), y: geometry.size.height * 0.5)
                                    Rectangle().fill(Color.primary.opacity(0.48)).frame(width: 1, height: geometry.size.height)
                                } else {
                                    Capsule().fill(signalColor(for: key))
                                        .frame(width: geometry.size.width * signalProgress(for: key, slot: slot))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(height: 3)
                        .animation(.linear(duration: 0.1), value: signalProgress(for: key, slot: slot))
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
    }

    private func displaySignalName(_ key: String, slot: Int) -> String {
        let prefix = slot == 1 ? "" : "2/"
        return String(key.dropFirst(prefix.count))
    }

    private func signalProgress(for key: String, slot: Int) -> CGFloat {
        let value = Double(manager.preview[key] ?? 0)
        return CGFloat(min(max(value, 0), 1))
    }

    private func isSignedSignal(_ key: String, slot: Int) -> Bool {
        let name = displaySignalName(key, slot: slot)
        let signedSignals: Set<String> = [
            "c/lx", "c/ly", "c/rx", "c/ry",
            "c/acc/x", "c/acc/y", "c/acc/z",
            "c/gyro/x", "c/gyro/y", "c/gyro/z",
            "c/attitude/x", "c/attitude/y", "c/attitude/z",
            "c/gravity/x", "c/gravity/y", "c/gravity/z",
            "c/useracc/x", "c/useracc/y", "c/useracc/z"
        ]
        return signedSignals.contains(name)
    }

    private func batteryText(_ level: Float?) -> String {
        guard let level else { return "--" }
        return "\(Int((level * 100).rounded()))%"
    }

    private func signalLegend(_ color: Color, _ title: String) -> some View {
        Label(title, systemImage: "circle.fill").labelStyle(.titleAndIcon).foregroundStyle(color)
    }

    private func copyAdvancedText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct AdaptiveTriggerNumberField: NSViewRepresentable {
    let value: Binding<Double>
    let range: ClosedRange<Double>

    private var precision: Int { range.upperBound > 1 ? 0 : 2 }
    private func formatted(_ value: Double) -> String {
        String(format: precision == 0 ? "%.0f" : "%.2f", value)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: formatted(value.wrappedValue))
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .labelColor
        field.focusRingType = .none
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Do not replace a partially typed value. Sync external OSC/slider
        // changes only while the field is not being edited.
        if field.currentEditor() == nil {
            field.stringValue = formatted(value.wrappedValue)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AdaptiveTriggerNumberField
        init(_ parent: AdaptiveTriggerNumberField) { self.parent = parent }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue.replacingOccurrences(of: ",", with: ".")
            if let parsed = Double(text), parsed.isFinite {
                parent.value.wrappedValue = min(max(parsed, parent.range.lowerBound), parent.range.upperBound)
            }
            field.stringValue = parent.formatted(parent.value.wrappedValue)
        }
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
