import Combine
import Foundation
import GameController

/// Maps a stick vector through a circular deadzone while preserving its angle.
enum StickDeadzone {
    static func apply(x: Float, y: Float, deadzone: Double) -> (x: Float, y: Float) {
        let radius = hypot(x, y)
        let dz = Float(min(max(deadzone, 0), 0.95))
        guard radius > dz, radius > 0 else { return (0, 0) }
        let outputRadius = min((min(radius, 1) - dz) / (1 - dz), 1)
        let scale = outputRadius / radius
        return (x * scale, y * scale)
    }
}

@MainActor
final class PS5Manager: ObservableObject {
    @Published var isConnected = false
    @Published var controllerName = "等待控制器連線…"
    @Published private(set) var batteryLevel: Float?
    @Published var networkStatus = "尚未設定目的地"
    @Published private(set) var preview: [String: Float] = [:]
    @Published private(set) var sampledFrames = 0
    @Published var midiEnabled: Bool {
        didSet {
            save("midiEnabled", midiEnabled)
            if midiEnabled {
                midiOutput.resetStateCache()
            } else {
                midiOutput.sendNeutral()
            }
        }
    }
    @Published var midiMotionEnabled: Bool {
        didSet {
            save("midiMotionEnabled", midiMotionEnabled)
            if midiMotionEnabled {
                midiOutput.resetMotionStateCache()
            } else if midiEnabled {
                midiOutput.sendMotionNeutral()
            }
        }
    }

    var midiAvailable: Bool { midiOutput.isAvailable }
    var midiSourceName: String { midiOutput.sourceName }
    var midiLearnAvailable: Bool { midiOutput.isLearnAvailable }
    var midiLearnSourceName: String { midiOutput.learnSourceName }
    var midiLearnStatus: String {
        guard midiOutput.isLearnAvailable else {
            return "建立失敗 · OSStatus \(midiOutput.learnInitializationError ?? -1)"
        }
        return "變更時傳送 · \(midiOutput.sentLearnUpdates.formatted()) 次"
    }
    var midiStatus: String {
        guard midiEnabled else { return "已停用" }
        guard midiOutput.isAvailable else { return "來源建立失敗 · OSStatus \(midiOutput.initializationError ?? -1)" }
        guard isConnected else { return "等待手把" }
        return midiOutput.lastSendSucceeded ? "來源正在送出" : "來源就緒，等待訊號"
    }
    var midiFramesSent: Int { midiOutput.sentFrames }

    @Published var targetIP: String { didSet { save("targetIP", targetIP); updateDestination() } }
    @Published var targetPort: String { didSet { save("targetPort", targetPort); updateDestination() } }
    @Published var deadzoneL: Double { didSet { save("deadzoneL", deadzoneL) } }
    @Published var deadzoneR: Double { didSet { save("deadzoneR", deadzoneR) } }
    @Published var invertLX: Bool { didSet { save("invertLX", invertLX) } }
    @Published var invertLY: Bool { didSet { save("invertLY", invertLY) } }
    @Published var invertRX: Bool { didSet { save("invertRX", invertRX) } }
    @Published var invertRY: Bool { didSet { save("invertRY", invertRY) } }
    @Published var invertAccelX: Bool { didSet { save("invertAccelX", invertAccelX) } }
    @Published var invertAccelY: Bool { didSet { save("invertAccelY", invertAccelY) } }
    @Published var invertAccelZ: Bool { didSet { save("invertAccelZ", invertAccelZ) } }
    @Published var invertGyroX: Bool { didSet { save("invertGyroX", invertGyroX) } }
    @Published var invertGyroY: Bool { didSet { save("invertGyroY", invertGyroY) } }
    @Published var invertGyroZ: Bool { didSet { save("invertGyroZ", invertGyroZ) } }

    private let oscClient = SimpleOSCClient()
    private let midiOutput = MIDIOutput()
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var sampleTimer: Timer?
    private var statusTimer: Timer?
    private var previewTimer: Timer?
    private var activeController: GCController?
    private var pendingPreview: [String: Float] = [:]
    private var totalSampledFrames = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        midiEnabled = defaults.object(forKey: "midiEnabled") as? Bool ?? true
        midiMotionEnabled = defaults.object(forKey: "midiMotionEnabled") as? Bool ?? false
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
            Task { @MainActor [weak self] in self?.networkStatus = message }
        }
        updateDestination()
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectAvailableController() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.controllerDisconnected() }
        })
        GCController.startWirelessControllerDiscovery(completionHandler: {})
        selectAvailableController()
    }

    deinit {
        sampleTimer?.invalidate()
        statusTimer?.invalidate()
        previewTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    private func updateDestination() {
        let port = UInt16(targetPort.trimmingCharacters(in: .whitespacesAndNewlines))
        oscClient.configure(host: targetIP, port: port)
    }

    private func selectAvailableController() {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad is GCDualSenseGamepad }) else {
            if activeController != nil || isConnected { disconnectActiveController() }
            return
        }
        guard activeController !== controller else { return }
        activate(controller)
    }

    private func controllerDisconnected() {
        guard activeController != nil else { selectAvailableController(); return }
        activeController = nil
        if let remaining = GCController.controllers().first(where: { $0.extendedGamepad is GCDualSenseGamepad }) {
            activate(remaining)
        } else {
            disconnectActiveController()
        }
    }

    private func activate(_ controller: GCController) {
        activeController = controller
        midiOutput.resetStateCache()
        isConnected = true
        controllerName = controller.vendorName ?? "DualSense"
        controller.motion?.sensorsActive = true
        startTimers()
        sendStatus() // Send connection state immediately.
        sample()
    }

    private func disconnectActiveController() {
        activeController?.motion?.sensorsActive = false
        activeController = nil
        stopTimers()
        sendNeutralControlState()
        if midiEnabled { midiOutput.sendNeutral() }
        isConnected = false
        controllerName = "等待 DualSense 連線…"
        batteryLevel = nil
        pendingPreview = ["s/connected": 0]
        preview = pendingPreview
        sampledFrames = totalSampledFrames
        oscClient.send([OSCMessage(address: "/ds/s/connected", value: 0)])
    }

    private func startTimers() {
        stopTimers()
        sampleTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        statusTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sendStatus()
                self.sampledFrames = self.totalSampledFrames
            }
        }
        previewTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.preview = self.pendingPreview
            }
        }
        if let sampleTimer { RunLoop.main.add(sampleTimer, forMode: .common) }
        if let statusTimer { RunLoop.main.add(statusTimer, forMode: .common) }
        if let previewTimer { RunLoop.main.add(previewTimer, forMode: .common) }
    }

    private func stopTimers() {
        sampleTimer?.invalidate(); sampleTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        previewTimer?.invalidate(); previewTimer = nil
    }

    func prepareForExit() {
        activeController?.motion?.sensorsActive = false
        stopTimers()
        sendNeutralControlState()
        if midiEnabled { midiOutput.sendNeutral() }
        oscClient.send([OSCMessage(address: "/ds/s/connected", value: 0)])
    }

    private func sendNeutralControlState() {
        let paths = [
            "lx", "ly", "rx", "ry", "l2", "r2", "l1", "r1",
            "cross", "circle", "square", "triangle", "du", "dd", "dl", "dr",
            "options", "menu", "l3", "r3", "tclick",
            "t1/x", "t1/y", "t1/touch", "t2/x", "t2/y", "t2/touch",
            "acc/x", "acc/y", "acc/z", "gyro/x", "gyro/y", "gyro/z"
        ]
        let neutral = paths.map { OSCMessage(address: "/ds/c/\($0)", value: 0) }
        oscClient.send(neutral)
        for path in paths { pendingPreview["c/\(path)"] = 0 }
    }

    private func sample() {
        guard let controller = activeController,
              let pad = controller.extendedGamepad as? GCDualSenseGamepad else { return }
        var messages: [OSCMessage] = []
        var current: [String: Float] = [:]
        func put(_ path: String, _ value: Float) {
            messages.append(OSCMessage(address: "/ds/c/\(path)", value: value))
            current["c/\(path)"] = value
        }
        func pressed(_ path: String, _ input: GCControllerButtonInput?) {
            if let input { put(path, input.isPressed ? 1 : 0) }
        }
        func sign(_ value: Float, inverted: Bool) -> Float { inverted ? -value : value }

        let left = StickDeadzone.apply(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value, deadzone: deadzoneL)
        let right = StickDeadzone.apply(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value, deadzone: deadzoneR)
        put("lx", sign(left.x, inverted: invertLX)); put("ly", sign(left.y, inverted: invertLY))
        put("rx", sign(right.x, inverted: invertRX)); put("ry", sign(right.y, inverted: invertRY))
        put("l2", pad.leftTrigger.value); put("r2", pad.rightTrigger.value)
        pressed("l1", pad.leftShoulder); pressed("r1", pad.rightShoulder)
        pressed("cross", pad.buttonA); pressed("circle", pad.buttonB)
        pressed("square", pad.buttonX); pressed("triangle", pad.buttonY)
        pressed("du", pad.dpad.up); pressed("dd", pad.dpad.down)
        pressed("dl", pad.dpad.left); pressed("dr", pad.dpad.right)
        pressed("options", pad.buttonOptions); pressed("menu", pad.buttonMenu)
        pressed("l3", pad.leftThumbstickButton); pressed("r3", pad.rightThumbstickButton)
        pressed("tclick", pad.touchpadButton)

        let p1x = pad.touchpadPrimary.xAxis.value, p1y = pad.touchpadPrimary.yAxis.value
        let p2x = pad.touchpadSecondary.xAxis.value, p2y = pad.touchpadSecondary.yAxis.value
        // GameController exposes DualSense finger locations as axes and reports (0, 0)
        // when a finger lifts. Treat tiny residual values as released to prevent touch jitter.
        let p1Touched = max(abs(p1x), abs(p1y)) > 0.015
        let p2Touched = max(abs(p2x), abs(p2y)) > 0.015
        put("t1/x", p1Touched ? p1x : 0); put("t1/y", p1Touched ? p1y : 0); put("t1/touch", p1Touched ? 1 : 0)
        put("t2/x", p2Touched ? p2x : 0); put("t2/y", p2Touched ? p2y : 0); put("t2/touch", p2Touched ? 1 : 0)

        if let motion = controller.motion {
            put("acc/x", Float(motion.acceleration.x) * (invertAccelX ? -1 : 1))
            put("acc/y", Float(motion.acceleration.y) * (invertAccelY ? -1 : 1))
            put("acc/z", Float(motion.acceleration.z) * (invertAccelZ ? -1 : 1))
            put("gyro/x", Float(motion.rotationRate.x) * (invertGyroX ? -1 : 1))
            put("gyro/y", Float(motion.rotationRate.y) * (invertGyroY ? -1 : 1))
            put("gyro/z", Float(motion.rotationRate.z) * (invertGyroZ ? -1 : 1))
        }
        for (key, value) in current { pendingPreview[key] = value }
        oscClient.send(messages)
        if midiEnabled { midiOutput.send(frame: current, includeMotion: midiMotionEnabled) }
        totalSampledFrames += 1
    }

    private func sendStatus() {
        guard let controller = activeController else { return }
        var status = [OSCMessage(address: "/ds/s/connected", value: 1)]
        pendingPreview["s/connected"] = 1
        if let battery = controller.battery?.batteryLevel {
            batteryLevel = battery
            status.append(OSCMessage(address: "/ds/s/battery", value: battery))
            pendingPreview["s/battery"] = battery
        } else {
            batteryLevel = nil
            pendingPreview.removeValue(forKey: "s/battery")
        }
        oscClient.send(status)
    }
}
