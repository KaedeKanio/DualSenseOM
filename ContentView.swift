import SwiftUI
import Combine
import GameController
import Network

// MARK: - 1. 原生 OSC 發送器
class SimpleOSCClient {
    private var connection: NWConnection?
    private var currentIP: String = ""
    private var currentPort: UInt16 = 0
    
    func send(address: String, value: Float, to ip: String, port: UInt16) {
        if connection == nil || currentIP != ip || currentPort != port {
            connection?.cancel()
            currentIP = ip
            currentPort = port
            if let nwPort = NWEndpoint.Port(rawValue: port) {
                connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(ip), port: nwPort), using: .udp)
                connection?.start(queue: .global(qos: .userInteractive))
            }
        }
        let data = encodeOSC(address: address, value: value)
        connection?.send(content: data, completion: .idempotent)
    }
    
    private func encodeOSC(address: String, value: Float) -> Data {
        var data = Data()
        if let addrData = address.data(using: .utf8) { data.append(addrData) }
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        data.append(contentsOf: [44, 102, 0, 0])
        var bitPattern = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bitPattern) { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: - 2. 核心大腦 (雙指觸控板修正版)
class PS5Manager: ObservableObject {
    @Published var isConnected = false
    @AppStorage("targetIP") var targetIP: String = "127.0.0.1"
    @AppStorage("targetPort") var targetPort: String = "9999"
    
    @AppStorage("deadzoneL") var deadzoneL: Double = 0.05
    @AppStorage("deadzoneR") var deadzoneR: Double = 0.05
    @AppStorage("invertLX") var invertLX: Bool = false
    @AppStorage("invertLY") var invertLY: Bool = false
    @AppStorage("invertRX") var invertRX: Bool = false
    @AppStorage("invertRY") var invertRY: Bool = false
    
    @AppStorage("invertAccelX") var invertAccelX: Bool = false
    @AppStorage("invertAccelY") var invertAccelY: Bool = false
    @AppStorage("invertAccelZ") var invertAccelZ: Bool = false
    @AppStorage("invertGyroX") var invertGyroX: Bool = true
    @AppStorage("invertGyroY") var invertGyroY: Bool = true
    @AppStorage("invertGyroZ") var invertGyroZ: Bool = true
    
    private let oscClient = SimpleOSCClient()
    private var activity: NSObjectProtocol?
    private var backgroundTimer: DispatchSourceTimer?
    private weak var activeController: GCController?
    
    init() {
        GCController.shouldMonitorBackgroundEvents = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Keep OSC Background")
        
        NotificationCenter.default.addObserver(self, selector: #selector(didConnect), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didDisconnect), name: .GCControllerDidDisconnect, object: nil)
        
        if let controller = GCController.controllers().first {
            setupController(controller)
        }
    }
    
    @objc private func didConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        setupController(controller)
    }
    
    @objc private func didDisconnect(_ notification: Notification) {
        DispatchQueue.main.async { self.isConnected = false }
        activeController = nil
        backgroundTimer?.cancel()
        backgroundTimer = nil
    }
    
    private func setupController(_ controller: GCController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak controller] in
            guard let self = self, let padController = controller else { return }
            guard padController.physicalInputProfile as? GCDualSenseGamepad != nil else { return }
            
            self.isConnected = true
            self.activeController = padController
            padController.motion?.sensorsActive = true
            
            self.backgroundTimer?.cancel()
            self.backgroundTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            self.backgroundTimer?.schedule(deadline: .now(), repeating: 1.0 / 60.0)
            self.backgroundTimer?.setEventHandler { [weak self, weak padController] in
                guard let self = self, let pad = padController?.physicalInputProfile as? GCDualSenseGamepad else { return }
                self.sendAllData(from: pad, motion: padController?.motion)
            }
            self.backgroundTimer?.resume()
        }
    }
    
    private func processAxis(_ value: Float, deadzone: Double, invert: Bool) -> Float {
        let dz = Float(deadzone)
        var out: Float = 0.0
        if abs(value) > dz {
            let sign = value > 0 ? 1.0 : -1.0
            out = ((abs(value) - dz) / (1.0 - dz)) * Float(sign)
        }
        return invert ? -out : out
    }
    
    private func sendAllData(from pad: GCDualSenseGamepad, motion: GCMotion?) {
        guard let portInt = UInt16(self.targetPort) else { return }
        let ip = self.targetIP
        let c = self.oscClient
        let prefix = "/DualSenceTD"
        
        // --- 1. 雙搖桿 ---
        let lx = processAxis(pad.leftThumbstick.xAxis.value, deadzone: deadzoneL, invert: invertLX)
        let ly = processAxis(pad.leftThumbstick.yAxis.value, deadzone: deadzoneL, invert: invertLY)
        let rx = processAxis(pad.rightThumbstick.xAxis.value, deadzone: deadzoneR, invert: invertRX)
        let ry = processAxis(pad.rightThumbstick.yAxis.value, deadzone: deadzoneR, invert: invertRY)
        
        c.send(address: "\(prefix)/stick/left/x", value: lx, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/left/y", value: ly, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/right/x", value: rx, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/right/y", value: ry, to: ip, port: portInt)
        
        // --- 2. 扳機與按鍵 ---
        c.send(address: "\(prefix)/trigger/L2", value: pad.leftTrigger.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/trigger/R2", value: pad.rightTrigger.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/L1", value: pad.leftShoulder.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/R1", value: pad.rightShoulder.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        c.send(address: "\(prefix)/button/cross", value: pad.buttonA.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/circle", value: pad.buttonB.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/square", value: pad.buttonX.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/triangle", value: pad.buttonY.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        c.send(address: "\(prefix)/dpad/up", value: pad.dpad.up.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/dpad/down", value: pad.dpad.down.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/dpad/left", value: pad.dpad.left.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/dpad/right", value: pad.dpad.right.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        c.send(address: "\(prefix)/button/options", value: pad.buttonOptions?.isPressed == true ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/menu", value: pad.buttonMenu.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/L3", value: pad.leftThumbstickButton?.isPressed == true ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/R3", value: pad.rightThumbstickButton?.isPressed == true ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/touchpad", value: pad.touchpadButton.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        // --- 3. 觸控板雙指座標解析 ---
        let primary = pad.touchpadPrimary
        let primaryActive: Float = (abs(primary.xAxis.value) > 0.001 || abs(primary.yAxis.value) > 0.001) ? 1.0 : 0.0
        c.send(address: "\(prefix)/touchpad/primary/x", value: Float(primary.xAxis.value), to: ip, port: portInt)
        c.send(address: "\(prefix)/touchpad/primary/y", value: Float(primary.yAxis.value), to: ip, port: portInt)
        c.send(address: "\(prefix)/touchpad/primary/touching", value: primaryActive, to: ip, port: portInt)
        
        let secondary = pad.touchpadSecondary
        let secondaryActive: Float = (abs(secondary.xAxis.value) > 0.001 || abs(secondary.yAxis.value) > 0.001) ? 1.0 : 0.0
        c.send(address: "\(prefix)/touchpad/secondary/x", value: Float(secondary.xAxis.value), to: ip, port: portInt)
        c.send(address: "\(prefix)/touchpad/secondary/y", value: Float(secondary.yAxis.value), to: ip, port: portInt)
        c.send(address: "\(prefix)/touchpad/secondary/touching", value: secondaryActive, to: ip, port: portInt)
        
        // --- 4. 6軸體感 ---
        if let m = motion {
            let ax = Float(m.acceleration.x) * (invertAccelX ? -1.0 : 1.0)
            let ay = Float(m.acceleration.y) * (invertAccelY ? -1.0 : 1.0)
            let az = Float(m.acceleration.z) * (invertAccelZ ? -1.0 : 1.0)
            
            let gx = Float(m.rotationRate.x) * (invertGyroX ? -1.0 : 1.0)
            let gy = Float(m.rotationRate.y) * (invertGyroY ? -1.0 : 1.0)
            let gz = Float(m.rotationRate.z) * (invertGyroZ ? -1.0 : 1.0)
            
            c.send(address: "\(prefix)/motion/accel/x", value: ax, to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/accel/y", value: ay, to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/accel/z", value: az, to: ip, port: portInt)
            
            c.send(address: "\(prefix)/motion/gyro/x", value: gx, to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/gyro/y", value: gy, to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/gyro/z", value: gz, to: ip, port: portInt)
        }
    }
}

// MARK: - 3. 選單列小視窗 (Menu Bar)
struct ContentView: View {
    @ObservedObject var manager: PS5Manager
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(manager.isConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(manager.isConnected ? "PS5 手把已連線" : "等待手把連線...")
                    .font(.headline)
            }
            .padding(.top, 10)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("OSC 網路狀態").font(.caption).foregroundColor(.gray).bold()
                HStack {
                    Text("發送至 TD:")
                    Spacer()
                    Text("\(manager.targetIP):\(manager.targetPort)").foregroundColor(.blue)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            
            Divider()
            
            Button(action: {
                openWindow(id: "settings")
            }) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("打開進階設定 (死區/反轉)")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            
            Divider()
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("結束程式 (Quit)")
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.red)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 240)
    }
}

// MARK: - 4. 獨立進階設定視窗 (Settings Window)
struct SettingsView: View {
    @ObservedObject var manager: PS5Manager
    
    var body: some View {
        Form {
            Section(header: Text("網路設定 (OSC Target)").font(.headline)) {
                HStack {
                    Text("TD IP:")
                        .frame(width: 60, alignment: .leading)
                    TextField("127.0.0.1", text: $manager.targetIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                HStack {
                    Text("發送 Port:")
                        .frame(width: 60, alignment: .leading)
                    TextField("9999", text: $manager.targetPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
            Divider().padding(.vertical, 5)
            
            Section(header: Text("搖桿微調 (Sticks)").font(.headline)) {
                VStack(alignment: .leading) {
                    Text("左搖桿死區: \(manager.deadzoneL, specifier: "%.2f")")
                    Slider(value: $manager.deadzoneL, in: 0...0.5)
                    HStack {
                        Toggle("反轉左 X", isOn: $manager.invertLX)
                        Toggle("反轉左 Y", isOn: $manager.invertLY)
                    }
                }
                .padding(.bottom, 10)
                
                VStack(alignment: .leading) {
                    Text("右搖桿死區: \(manager.deadzoneR, specifier: "%.2f")")
                    Slider(value: $manager.deadzoneR, in: 0...0.5)
                    HStack {
                        Toggle("反轉右 X", isOn: $manager.invertRX)
                        Toggle("反轉右 Y", isOn: $manager.invertRY)
                    }
                }
            }
            Divider().padding(.vertical, 5)
            
            Section(header: Text("體感反轉 (Motion Invert)").font(.headline)) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("加速度計 (Accel)").font(.subheadline).foregroundColor(.gray)
                        Toggle("反轉 Accel X", isOn: $manager.invertAccelX)
                        Toggle("反轉 Accel Y", isOn: $manager.invertAccelY)
                        Toggle("反轉 Accel Z", isOn: $manager.invertAccelZ)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("陀螺儀 (Gyro)").font(.subheadline).foregroundColor(.gray)
                        Toggle("反轉 Gyro X", isOn: $manager.invertGyroX)
                        Toggle("反轉 Gyro Y", isOn: $manager.invertGyroY)
                        Toggle("反轉 Gyro Z", isOn: $manager.invertGyroZ)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 450)
        .onAppear {
            for window in NSApplication.shared.windows {
                if window.title == "進階設定 (DualSenseTD Settings)" {
                    window.level = .floating
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                }
            }
        }
    }
}
