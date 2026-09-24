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
        data.append(contentsOf: [44, 102, 0, 0])
        var bitPattern = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bitPattern) { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: - 2. 核心大腦
class PS5Manager: ObservableObject {
    @Published var isConnected = false
    @AppStorage("targetIP") var targetIP: String = "127.0.0.1"
    @AppStorage("targetPort") var targetPort: String = "9999"
    
    private let oscClient = SimpleOSCClient()
    private var activity: NSObjectProtocol?
    private var backgroundTimer: DispatchSourceTimer?
    
    init() {
        // 終極魔法開關：強制允許在背景監聽硬體控制器事件！
        GCController.shouldMonitorBackgroundEvents = true
        
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak controller] in
            guard let self = self, let padController = controller else { return }
            guard padController.physicalInputProfile as? GCDualSenseGamepad != nil else { return }
            
            self.isConnected = true
            padController.motion?.sensorsActive = true
            
            self.backgroundTimer?.cancel()
            self.backgroundTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            self.backgroundTimer?.schedule(deadline: .now(), repeating: 1.0 / 60.0)
            self.backgroundTimer?.setEventHandler { [weak self, weak padController] in
                guard let self = self,
                      let pad = padController?.physicalInputProfile as? GCDualSenseGamepad else { return }
                self.sendAllData(from: pad, motion: padController?.motion)
            }
            self.backgroundTimer?.resume()
        }
    }
    
    private func sendAllData(from pad: GCDualSenseGamepad, motion: GCMotion?) {
        guard let portInt = UInt16(self.targetPort) else { return }
        let ip = self.targetIP
        let c = self.oscClient
        let prefix = "/DualSenceTD"
        
        c.send(address: "\(prefix)/stick/left/x", value: pad.leftThumbstick.xAxis.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/left/y", value: pad.leftThumbstick.yAxis.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/right/x", value: pad.rightThumbstick.xAxis.value, to: ip, port: portInt)
        c.send(address: "\(prefix)/stick/right/y", value: pad.rightThumbstick.yAxis.value, to: ip, port: portInt)
        
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
        
        if let m = motion {
            c.send(address: "\(prefix)/motion/accel/x", value: Float(m.acceleration.x), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/accel/y", value: Float(m.acceleration.y), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/accel/z", value: Float(m.acceleration.z), to: ip, port: portInt)
            
            c.send(address: "\(prefix)/motion/gyro/x", value: Float(m.rotationRate.x), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/gyro/y", value: Float(m.rotationRate.y), to: ip, port: portInt)
            c.send(address: "\(prefix)/motion/gyro/z", value: Float(m.rotationRate.z), to: ip, port: portInt)
        }
    }
}

// MARK: - 3. 介面設計 (選單列專用面板)
struct ContentView: View {
    @StateObject private var ps5Manager = PS5Manager()
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(ps5Manager.isConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(ps5Manager.isConnected ? "PS5 手把已連線" : "等待手把連線...")
                    .font(.headline)
            }
            .padding(.top, 10)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("OSC Target")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                HStack {
                    Text("IP:")
                        .frame(width: 30, alignment: .leading)
                    TextField("127.0.0.1", text: $ps5Manager.targetIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                HStack {
                    Text("Port:")
                        .frame(width: 30, alignment: .leading)
                    TextField("9999", text: $ps5Manager.targetPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
            .padding(.horizontal, 10)
            
            Divider()
            
            // 離開按鈕
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
        .frame(width: 220) // 選單列下拉面板的寬度
    }
}
