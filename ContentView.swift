import SwiftUI
import Combine
import GameController
import Network
import AppKit

// MARK: - OSC over UDP

/// 所有 NWConnection 狀態都由 queue 管理。
/// 每次取樣的數值會放進同一個 OSC bundle 傳送。
final class SimpleOSCClient {
    /// Bundle order is intentional so TouchDesigner channels appear consistently.
    private static let oscKeyOrder = [
        "stick/left/x", "stick/left/y", "stick/right/x", "stick/right/y",
        "trigger/L2", "trigger/R2",
        "button/L1", "button/R1", "button/cross", "button/circle",
        "button/square", "button/triangle", "button/options", "button/menu",
        "button/L3", "button/R3", "button/touchpad",
        "dpad/up", "dpad/down", "dpad/left", "dpad/right",
        "touchpad/primary/x", "touchpad/primary/y", "touchpad/primary/touching",
        "touchpad/secondary/x", "touchpad/secondary/y", "touchpad/secondary/touching",
        "motion/accel/x", "motion/accel/y", "motion/accel/z",
        "motion/gyro/x", "motion/gyro/y", "motion/gyro/z",
        "status/battery", "status/connected"
    ]

    private let queue = DispatchQueue(label: "tw.luojie.dualsense-osc.network")
    private var connection: NWConnection?
    private var currentHost: String?
    private var currentPort: UInt16?
    private var lastReportedSendError: String?

    var onStatusChange: ((String) -> Void)?

    func configure(host: String, port: UInt16?) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let port,
                  port > 0,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.connection?.cancel()
                self.connection = nil
                self.currentHost = nil
                self.currentPort = nil
                self.report("請輸入有效的目標 IP 與 Port")
                return
            }

            guard self.currentHost != host
                    || self.currentPort != port
                    || self.connection == nil else {
                return
            }

            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()

            self.currentHost = host
            self.currentPort = port
            self.openConnection()
        }
    }

    func send(addressPrefix: String, values: [String: Float]) {
        guard !values.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }

            if self.connection == nil {
                self.openConnection()
            }

            guard let connection = self.connection else { return }

            let packet = Self.encodeBundle(
                prefix: addressPrefix,
                values: values
            )

            connection.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.reportSendError(error)
                    }
                }
            )
        }
    }

    private func openConnection() {
        guard let host = currentHost,
              let port = currentPort,
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return
        }

        let connection = NWConnection(
            to: .hostPort(
                host: NWEndpoint.Host(host),
                port: endpointPort
            ),
            using: .udp
        )

        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }

            switch state {
            case .ready:
                self.lastReportedSendError = nil
                self.report("UDP 已就緒；等待接收端")

            case .setup, .preparing:
                self.report("正在連接 UDP…")

            case .waiting(let error):
                self.report("等待網路：\(error.localizedDescription)")

            case .failed(let error):
                self.reportSendError(error)

                if self.connection === connection {
                    self.connection = nil
                }

            case .cancelled:
                break

            @unknown default:
                self.report("UDP 狀態未知")
            }
        }

        connection.start(queue: queue)
    }

    private func reportSendError(_ error: NWError) {
        let message: String
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            message = "接收端拒絕 UDP：請確認 TouchDesigner 的 OSC In 已啟用，且 Target IP / Port 相符。"
        case .posix(let code) where code == .EHOSTUNREACH || code == .ENETUNREACH:
            message = "找不到 UDP 接收端：請確認 Mac 與 Target IP 的網路連線。"
        default:
            message = "UDP 傳送錯誤：\(error.localizedDescription)"
        }

        guard lastReportedSendError != message else { return }
        lastReportedSendError = message
        report(message)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(message)
        }
    }

    private static func encodeBundle(
        prefix: String,
        values: [String: Float]
    ) -> Data {
        var bundle = Data("#bundle\0".utf8)

        // OSC immediate timetag
        appendUInt64(1, to: &bundle)

        let knownKeys = Set(Self.oscKeyOrder)
        let orderedKeys = Self.oscKeyOrder.filter { values[$0] != nil }
        let extraKeys = values.keys.filter { !knownKeys.contains($0) }.sorted()

        for key in orderedKeys + extraKeys {
            guard let value = values[key] else { continue }

            let message = encodeMessage(
                address: "\(prefix)/\(key)",
                value: value
            )

            appendUInt32(UInt32(message.count), to: &bundle)
            bundle.append(message)
        }

        return bundle
    }

    private static func encodeMessage(
        address: String,
        value: Float
    ) -> Data {
        var data = Data()
        appendOSCString(address, to: &data)
        appendOSCString(",f", to: &data)
        appendUInt32(value.bitPattern, to: &data)
        return data
    }

    private static func appendOSCString(
        _ string: String,
        to data: inout Data
    ) {
        data.append(contentsOf: string.utf8)
        data.append(0)

        while data.count % 4 != 0 {
            data.append(0)
        }
    }

    private static func appendUInt32(
        _ value: UInt32,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func appendUInt64(
        _ value: UInt64,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }
}

// MARK: - Controller and settings model

@MainActor
final class PS5Manager: ObservableObject {
    @Published var isConnected = false
    @Published var controllerName = "等待控制器連線…"
    @Published private(set) var batteryLevel: Float?
    @Published var networkStatus = "尚未設定目的地"
    @Published private(set) var preview: [String: Float] = [:]
    @Published private(set) var framesSent = 0

    @Published var targetIP: String {
        didSet {
            save("targetIP", targetIP)
            updateDestination()
        }
    }

    @Published var targetPort: String {
        didSet {
            save("targetPort", targetPort)
            updateDestination()
        }
    }

    @Published var deadzoneL: Double {
        didSet { save("deadzoneL", deadzoneL) }
    }

    @Published var deadzoneR: Double {
        didSet { save("deadzoneR", deadzoneR) }
    }

    @Published var invertLX: Bool {
        didSet { save("invertLX", invertLX) }
    }

    @Published var invertLY: Bool {
        didSet { save("invertLY", invertLY) }
    }

    @Published var invertRX: Bool {
        didSet { save("invertRX", invertRX) }
    }

    @Published var invertRY: Bool {
        didSet { save("invertRY", invertRY) }
    }

    @Published var invertAccelX: Bool {
        didSet { save("invertAccelX", invertAccelX) }
    }

    @Published var invertAccelY: Bool {
        didSet { save("invertAccelY", invertAccelY) }
    }

    @Published var invertAccelZ: Bool {
        didSet { save("invertAccelZ", invertAccelZ) }
    }

    @Published var invertGyroX: Bool {
        didSet { save("invertGyroX", invertGyroX) }
    }

    @Published var invertGyroY: Bool {
        didSet { save("invertGyroY", invertGyroY) }
    }

    @Published var invertGyroZ: Bool {
        didSet { save("invertGyroZ", invertGyroZ) }
    }

    private let oscClient = SimpleOSCClient()
    private let addressPrefix = "/DualSenseTD"
    private let defaults: UserDefaults

    private var observers: [NSObjectProtocol] = []
    private var sampleTimer: Timer?
    private var activeController: GCController?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        targetIP = defaults.string(forKey: "targetIP") ?? "127.0.0.1"
        targetPort = defaults.string(forKey: "targetPort") ?? "9999"

        deadzoneL = defaults.object(forKey: "deadzoneL") as? Double ?? 0.05
        deadzoneR = defaults.object(forKey: "deadzoneR") as? Double ?? 0.05

        invertLX = defaults.object(forKey: "invertLX") as? Bool ?? false
        invertLY = defaults.object(forKey: "invertLY") as? Bool ?? false
        invertRX = defaults.object(forKey: "invertRX") as? Bool ?? false
        invertRY = defaults.object(forKey: "invertRY") as? Bool ?? false

        invertAccelX = defaults.object(forKey: "invertAccelX") as? Bool ?? false
        invertAccelY = defaults.object(forKey: "invertAccelY") as? Bool ?? false
        invertAccelZ = defaults.object(forKey: "invertAccelZ") as? Bool ?? false

        invertGyroX = defaults.object(forKey: "invertGyroX") as? Bool ?? true
        invertGyroY = defaults.object(forKey: "invertGyroY") as? Bool ?? true
        invertGyroZ = defaults.object(forKey: "invertGyroZ") as? Bool ?? true

        oscClient.onStatusChange = { [weak self] message in
            Task { @MainActor in
                self?.networkStatus = message
            }
        }

        updateDestination()
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.selectAvailableController()
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.controllerDisconnected(nil)
                }
            }
        )

        GCController.startWirelessControllerDiscovery(completionHandler: {})
        selectAvailableController()
    }

    deinit {
        sampleTimer?.invalidate()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    private func updateDestination() {
        let port = UInt16(
            targetPort.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        oscClient.configure(
            host: targetIP.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port
        )
    }

    private func selectAvailableController() {
        guard let controller = GCController.controllers().first(where: {
            $0.extendedGamepad is GCDualSenseGamepad
        }) else {
            activeController = nil
            sampleTimer?.invalidate()
            sampleTimer = nil
            isConnected = false
            controllerName = "等待 DualSense 連線…"
            batteryLevel = nil
            preview = ["status/connected": 0]

            oscClient.send(
                addressPrefix: addressPrefix,
                values: ["status/connected": 0]
            )
            return
        }

        guard activeController !== controller else { return }

        activeController = controller
        isConnected = true
        controllerName = controller.vendorName ?? "DualSense"
        controller.motion?.sensorsActive = true

        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }

        sample()
    }

    private func controllerDisconnected(_ disconnected: GCController?) {
        guard disconnected == nil || disconnected === activeController else {
            return
        }

        if let remaining = GCController.controllers().first(where: {
            $0.extendedGamepad is GCDualSenseGamepad
        }) {
            activeController = nil
            selectSpecificController(remaining)
        } else {
            activeController = nil
            sampleTimer?.invalidate()
            sampleTimer = nil
            isConnected = false
            controllerName = "等待 DualSense 連線…"
            batteryLevel = nil
            preview = ["status/connected": 0]

            oscClient.send(
                addressPrefix: addressPrefix,
                values: ["status/connected": 0]
            )
        }
    }

    private func selectSpecificController(_ controller: GCController) {
        activeController = nil

        guard controller.extendedGamepad is GCDualSenseGamepad else {
            return
        }

        activeController = controller
        isConnected = true
        controllerName = controller.vendorName ?? "DualSense"
        controller.motion?.sensorsActive = true

        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }

        sample()
    }

    private func applyDeadzone(
        _ value: Float,
        deadzone: Double,
        inverted: Bool
    ) -> Float {
        let dz = Float(min(max(deadzone, 0), 0.95))
        let magnitude = abs(value)

        let adjusted: Float
        if magnitude <= dz {
            adjusted = 0
        } else {
            let sign: Float = value < 0 ? -1 : 1
            adjusted = (magnitude - dz) / (1 - dz) * sign
        }

        return inverted ? -adjusted : adjusted
    }

    private func sample() {
        guard let controller = activeController,
              let pad = controller.extendedGamepad as? GCDualSenseGamepad else {
            return
        }

        var values: [String: Float] = [:]

        func put(_ key: String, _ value: Float) {
            values[key] = value
        }

        func pressed(_ key: String, _ input: GCControllerButtonInput?) {
            if let input {
                put(key, input.isPressed ? 1 : 0)
            }
        }

        // Sticks
        put(
            "stick/left/x",
            applyDeadzone(
                pad.leftThumbstick.xAxis.value,
                deadzone: deadzoneL,
                inverted: invertLX
            )
        )
        put(
            "stick/left/y",
            applyDeadzone(
                pad.leftThumbstick.yAxis.value,
                deadzone: deadzoneL,
                inverted: invertLY
            )
        )
        put(
            "stick/right/x",
            applyDeadzone(
                pad.rightThumbstick.xAxis.value,
                deadzone: deadzoneR,
                inverted: invertRX
            )
        )
        put(
            "stick/right/y",
            applyDeadzone(
                pad.rightThumbstick.yAxis.value,
                deadzone: deadzoneR,
                inverted: invertRY
            )
        )

        // Triggers and buttons
        put("trigger/L2", pad.leftTrigger.value)
        put("trigger/R2", pad.rightTrigger.value)

        pressed("button/L1", pad.leftShoulder)
        pressed("button/R1", pad.rightShoulder)

        pressed("button/cross", pad.buttonA)
        pressed("button/circle", pad.buttonB)
        pressed("button/square", pad.buttonX)
        pressed("button/triangle", pad.buttonY)

        pressed("dpad/up", pad.dpad.up)
        pressed("dpad/down", pad.dpad.down)
        pressed("dpad/left", pad.dpad.left)
        pressed("dpad/right", pad.dpad.right)

        pressed("button/options", pad.buttonOptions)
        pressed("button/menu", pad.buttonMenu)
        pressed("button/L3", pad.leftThumbstickButton)
        pressed("button/R3", pad.rightThumbstickButton)
        pressed("button/touchpad", pad.touchpadButton)

        // Touchpad coordinates
        put("touchpad/primary/x", pad.touchpadPrimary.xAxis.value)
        put("touchpad/primary/y", pad.touchpadPrimary.yAxis.value)
        put("touchpad/secondary/x", pad.touchpadSecondary.xAxis.value)
        put("touchpad/secondary/y", pad.touchpadSecondary.yAxis.value)

        // Match the original implementation: derive each binary flag from its
        // corresponding DualSense touch coordinate pair.
        let primaryX = pad.touchpadPrimary.xAxis.value
        let primaryY = pad.touchpadPrimary.yAxis.value
        let secondaryX = pad.touchpadSecondary.xAxis.value
        let secondaryY = pad.touchpadSecondary.yAxis.value
        let primaryTouching = abs(primaryX) > 0.001 || abs(primaryY) > 0.001
        let secondaryTouching = abs(secondaryX) > 0.001 || abs(secondaryY) > 0.001
        put("touchpad/primary/touching", primaryTouching ? 1 : 0)
        put("touchpad/secondary/touching", secondaryTouching ? 1 : 0)

        // Motion
        if let motion = controller.motion {
            put(
                "motion/accel/x",
                Float(motion.acceleration.x) * (invertAccelX ? -1 : 1)
            )
            put(
                "motion/accel/y",
                Float(motion.acceleration.y) * (invertAccelY ? -1 : 1)
            )
            put(
                "motion/accel/z",
                Float(motion.acceleration.z) * (invertAccelZ ? -1 : 1)
            )

            put(
                "motion/gyro/x",
                Float(motion.rotationRate.x) * (invertGyroX ? -1 : 1)
            )
            put(
                "motion/gyro/y",
                Float(motion.rotationRate.y) * (invertGyroY ? -1 : 1)
            )
            put(
                "motion/gyro/z",
                Float(motion.rotationRate.z) * (invertGyroZ ? -1 : 1)
            )
        }

        batteryLevel = controller.battery?.batteryLevel
        if let battery = controller.battery {
            put("status/battery", battery.batteryLevel)
        }

        put("status/connected", 1)

        preview = values
        oscClient.send(addressPrefix: addressPrefix, values: values)
        framesSent += 1
    }
}

// MARK: - Menu bar interface

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

            Text("每秒更新 60 次 · \(manager.framesSent) 幀")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Link(
                "Designed by 羅苰榤",
                destination: URL(
                    string: "https://github.com/search?q=%E7%BE%85%E8%8B%B0%E6%A6%A4&type=users"
                )!
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

// MARK: - Settings window

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
                    "左搖桿死區",
                    value: $manager.deadzoneL
                )
                Toggle("反轉左 X", isOn: $manager.invertLX)
                Toggle("反轉左 Y", isOn: $manager.invertLY)

                deadzoneControl(
                    "右搖桿死區",
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
                    "PS 鍵與麥克風靜音鍵未由此 GameController profile 穩定提供；觸控板提供整體觸摸狀態，座標分別提供主／次觸點。"
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


// Keeps the advanced settings window above regular application windows.
private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FloatingWindowLevelView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FloatingWindowLevelView)?.applyFloatingLevel()
    }
}

private final class FloatingWindowLevelView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFloatingLevel()
    }

    func applyFloatingLevel() {
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
