import SwiftUI
import Combine
import GameController
import Network

// MARK: - 1. 原生 OSC 發送器
class SimpleOSCClient {
    private var connection: NWConnection?
    private var currentIP: String = ""
    private var currentPort: UInt16 = 0
    
    private func setupConnection(ip: String, port: UInt16) {
        if connection != nil && currentIP == ip && currentPort == port { return }
        connection?.cancel()
        currentIP = ip
        currentPort = port
        
        let host = NWEndpoint.Host(ip)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        
        connection = NWConnection(to: .hostPort(host: host, port: nwPort), using: .udp)
        connection?.start(queue: .global(qos: .userInteractive))
    }
    
    func send(address: String, value: Float, to ip: String, port: UInt16) {
        setupConnection(ip: ip, port: port)
        let data = encodeOSC(address: address, value: value)
        connection?.send(content: data, completion: .idempotent)
    }
    
    private func encodeOSC(address: String, value: Float) -> Data {
        var data = Data()
        if let addrData = address.data(using: .utf8) { data.append(addrData) }
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        data.append(contentsOf: [44, 102, 0, 0]) // ",f"
        var bitPattern = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bitPattern) { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: - 2. 核心大腦：底層背景防護與全數據讀取
class PS5Manager: ObservableObject {
    @Published var isConnected = false
    @AppStorage("targetIP") var targetIP: String = "127.0.0.1"
    @AppStorage("targetPort") var targetPort: String = "9999"
    
    private let oscClient = SimpleOSCClient()
    private var activity: NSObjectProtocol?
    private var backgroundTimer: DispatchSourceTimer?
    
    init() {
        // 阻擋 macOS 的 App Nap 休眠機制
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
        backgroundTimer?.cancel()
        backgroundTimer = nil
    }
    
    private func setupController(_ controller: GCController) {
        DispatchQueue.main.async { self.isConnected = true }
        
        // 喚醒手把的動態感測器
        controller.motion?.sensorsActive = true
        
        // 建立獨立於 UI 之外的 GCD 背景執行緒計時器
        backgroundTimer?.cancel()
        backgroundTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        backgroundTimer?.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        backgroundTimer?.setEventHandler { [weak self, weak controller] in
            guard let self = self,
                  let pad = controller?.physicalInputProfile as? GCDualSenseGamepad else { return }
            self.sendAllData(from: pad, motion: controller?.motion)
        }
        backgroundTimer?.resume()
    }
    
    private func sendAllData(from pad: GCDualSenseGamepad, motion: GCMotion?) {
        guard let portInt = UInt16(self.targetPort) else { return }
        let ip = self.targetIP
        let c = self.oscClient
        
        // 依照要求更改 Prefix
        let prefix = "/DualSenceTD"
        
        // --- 1. 雙搖桿 ---
        c.send(address: "\(prefix)/stick/left/x", value: pad.leftThumbstick.xAxis.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/left/y", value: pad.leftThumbstick.yAxis.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/right/x", value: pad.rightThumbstick.xAxis.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/right/y", value: pad.rightThumbstick.yAxis.value, to: ip, port: portInt)
        
        // --- 2. 感壓板機與肩鍵 ---
        c.send(address: "\(prefix)/trigger/L2", value: pad.leftTrigger.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/trigger/R2", value: pad.rightTrigger.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/L1", value: pad.leftShoulder.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/R1", value: pad.rightShoulder.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        // --- 3. 動作按鍵 (圈叉角方) ---
        c.send(address: "\(prefix)/button/cross", value: pad.buttonA.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/circle", value: pad.buttonB.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/square", value: pad.buttonX.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/triangle", value: pad.buttonY.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        // --- 4. 方向鍵 (D-Pad) ---
        c.send(address: "\(prefix)/dpad/up", value: pad.dpad.up.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/dpad/down", value: pad.dpad.down.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/dpad/left", value: pad.dpad.left.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/dpad/right", value: pad.dpad.right.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        // --- 5. 系統按鍵與 L3/R3 ---
        c.send(address: "\(prefix)/button/options", value: pad.buttonOptions?.isPressed == true ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/menu", value: pad.buttonMenu.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/L3", value: pad.leftThumbstickButton?.isPressed == true ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/R3", value: pad.rightThumbstickButton?.isPressed == true ? 1.0 : 0.0, to: ip, port: portInt)
        c.send(address: "\(prefix)/button/touchpad", value: pad.touchpadButton.isPressed ? 1.0 : 0.0, to: ip, port: portInt)
        
        // --- 6. 陀螺儀與加速度計 (Motion) ---
        if let m = motion {
            // 已修正：改用原始 acceleration 讀取包含重力的加速度
            c.send(address: "\(prefix)/motion/accel/x", value: Float(m.acceleration.x), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/accel/y", value: Float(m.acceleration.y), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/accel/z", value: Float(m.acceleration.z), to: ip, port: portInt)
            
            c.send(address: "\(prefix)/motion/gyro/x", value: Float(m.rotationRate.x), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/gyro/y", value: Float(m.rotationRate.y), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/gyro/z", value: Float(m.rotationRate.z), to: ip, port: portInt)
        }
    }
}

// MARK: - 3. 介面設計
struct ContentView: View {
    @StateObject private var ps5Manager = PS5Manager()
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Circle()
                    .fill(ps5Manager.isConnected ? Color.green : Color.red)
                    .frame(width: 15, height: 15)
                Text(ps5Manager.isConnected ? "PS5 手把已連線" : "等待手把連線...")
                    .font(.headline)
            }
            .padding(.top, 20)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("OSC Target")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                HStack {
                    Text("IP:")
                        .frame(width: 40, alignment: .leading)
                    TextField("127.0.0.1", text: $ps5Manager.targetIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                HStack {
                    Text("Port:")
                        .frame(width: 40, alignment: .leading)
                    TextField("9999", text: $ps5Manager.targetPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            
            Spacer()
            
            Link("Designed by 羅苰榤", destination: URL(string: "https://github.com")!)
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.bottom, 10)
        }
        .padding()
        .frame(width: 300, height: 260)
    }
}
