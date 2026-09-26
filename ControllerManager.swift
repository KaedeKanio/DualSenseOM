import Combine
import CoreHaptics
import Foundation
import GameController
import AppKit
import CoreFoundation
import IOKit
import IOKit.hid

struct RGBColor: Equatable {
    var red: Float
    var green: Float
    var blue: Float
}

enum ControllerBatteryState: Int, Equatable {
    case unknown = 0
    case discharging = 1
    case charging = 2
    case full = 3

    var title: String {
        switch self {
        case .unknown: "未知"
        case .discharging: "放電中"
        case .charging: "充電中"
        case .full: "已充滿"
        }
    }

    var chargingOSCValue: Float {
        switch self {
        case .unknown: -1
        case .charging: 1
        case .discharging, .full: 0
        }
    }
}

private struct ControllerInputSettings {
    var leftDeadzone: Double
    var rightDeadzone: Double
    var invertedAxes: Set<String>
}

struct AdaptiveTriggerSettings: Equatable {
    // 0 off, 1 feedback, 2 weapon, 3 vibration, 4 bow, 5 galloping, 6 machine
    var mode = 0
    var strength: Float = 0.5
    var strength2: Float = 0.5
    var start: Float = 0.2
    var end: Float = 0.8
    var frequency: Float = 0.5
    var period: Float = 0.5
}

private struct MotionFallbackState {
    var lastTime: TimeInterval?
    var qx: Double = 0
    var qy: Double = 0
    var qz: Double = 0
    var qw: Double = 1
    var gravityX: Double?
    var gravityY: Double?
    var gravityZ: Double?
}

struct ControllerSlotStatus: Identifiable, Equatable {
    let slot: Int
    var isConnected: Bool
    var name: String
    var batteryLevel: Float?
    var batteryState: ControllerBatteryState?
    var supportsLight: Bool?
    var supportsHaptics: Bool?
    var lightColor: RGBColor

    var id: Int { slot }
}

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
    @Published var networkStatus1 = "尚未設定目的地"
    @Published var networkStatus2 = "尚未設定目的地"
    @Published var oscReceiveStatus1 = "尚未啟動 OSC 接收"
    @Published var oscReceiveStatus2 = "尚未啟動 OSC 接收"
    @Published private(set) var preview: [String: Float] = [:]
    @Published private(set) var sampledFrames = 0
    @Published private(set) var controllerStatuses: [ControllerSlotStatus] = []
    @Published private(set) var hidTriggerStatus = "等待手把"
    @Published var hapticsOSCEnabled: Bool {
        didSet {
            save("hapticsOSCEnabled", hapticsOSCEnabled)
            if !hapticsOSCEnabled { stopHapticStreams() }
        }
    }

    @Published var midiEnabled: Bool {
        didSet {
            save("midiEnabled", midiEnabled)
            for slot in 1...2 {
                let channel = UInt8(slot)
                if midiEnabled { midiOutput.resetStateCache(channel: channel) }
                else { midiOutput.sendNeutral(channel: channel) }
            }
        }
    }
    @Published var midiMotionEnabled: Bool {
        didSet {
            save("midiMotionEnabled", midiMotionEnabled)
            for slot in 1...2 {
                let channel = UInt8(slot)
                if midiMotionEnabled { midiOutput.resetMotionStateCache(channel: channel) }
                else if midiEnabled { midiOutput.sendMotionNeutral(channel: channel) }
            }
        }
    }
    @Published var extendedMotionOSCEnabled: Bool {
        didSet {
            save("extendedMotionOSCEnabled", extendedMotionOSCEnabled)
            guard !extendedMotionOSCEnabled else { return }
            let paths = ["attitude/x", "attitude/y", "attitude/z", "attitude/w", "gravity/x", "gravity/y", "gravity/z", "useracc/x", "useracc/y", "useracc/z"]
            for slot in 1...2 {
                let zeros = paths.map { OSCMessage(address: controlAddress($0, slot: slot), value: 0) }
                oscClients[slot]?.send(zeros)
                for path in paths { pendingPreview[previewKey(path, slot: slot)] = 0 }
            }
        }
    }
    @Published private(set) var adaptiveTriggerSettings: [String: AdaptiveTriggerSettings] = [:]

    var midiAvailable: Bool { (1...2).allSatisfy { midiOutput.isAvailable(slot: $0) } }
    var midiSourceName: String { "\(midiOutput.sourceName(slot: 1)) · \(midiOutput.sourceName(slot: 2))" }
    var midiLearnAvailable: Bool { (1...2).allSatisfy { midiOutput.isLearnAvailable(slot: $0) } }
    var midiLearnSourceName: String { "\(midiOutput.learnSourceName(slot: 1)) · \(midiOutput.learnSourceName(slot: 2))" }
    func midiSourceName(slot: Int) -> String { midiOutput.sourceName(slot: slot) }
    func midiLearnSourceName(slot: Int) -> String { midiOutput.learnSourceName(slot: slot) }
    var midiLearnStatus: String {
        guard midiLearnAvailable else {
            let code = midiOutput.learnInitializationErrors[1] ?? midiOutput.learnInitializationErrors[2] ?? -1
            return "建立失敗 · OSStatus \(code)"
        }
        return "變更時傳送 · \(midiOutput.sentLearnUpdates.formatted()) 次"
    }
    var midiStatus: String {
        guard midiEnabled else { return "已停用" }
        guard midiAvailable else {
            let code = midiOutput.initializationErrors[1] ?? midiOutput.initializationErrors[2] ?? -1
            return "來源建立失敗 · OSStatus \(code)"
        }
        guard isConnected else { return "等待手把" }
        return midiOutput.lastSendSucceeded ? "來源正在送出" : "來源就緒，等待訊號"
    }
    var midiFramesSent: Int { midiOutput.sentFrames }

    @Published var targetIP: String { didSet { save("targetIP", targetIP); updateDestination() } }
    @Published var targetPort1: String { didSet { save("targetPort1", targetPort1); updateDestination() } }
    @Published var targetPort2: String { didSet { save("targetPort2", targetPort2); updateDestination() } }
    @Published var oscReceivePort1: String { didSet { save("oscReceivePort1", oscReceivePort1); updateReceiver(slot: 1) } }
    @Published var oscReceivePort2: String { didSet { save("oscReceivePort2", oscReceivePort2); updateReceiver(slot: 2) } }
    @Published private var inputSettings: [Int: ControllerInputSettings] = [:]

    private let oscClients = [1: SimpleOSCClient(), 2: SimpleOSCClient()]
    private let oscReceivers = [1: SimpleOSCReceiver(), 2: SimpleOSCReceiver()]
    private let midiOutput = MIDIOutput()
    private let defaults: UserDefaults
    private var hidIdentityByController: [ObjectIdentifier: String] = [:]
    private var hidMappingRetryTimer: Timer?
    private var hidMappingRetryAttempt = 0
    private var observers: [NSObjectProtocol] = []
    private var sampleTimer: Timer?
    private var statusTimer: Timer?
    private var previewTimer: Timer?
    private var controllersBySlot: [Int: GCController] = [:]
    private var hapticEngines: [Int: CHHapticEngine] = [:]
    private var hapticPlayers: [Int: CHHapticPatternPlayer] = [:]
    private var hapticTriggerActive: [Int: Bool] = [:]
    private var gripHapticPlayers: [Int: CHHapticPatternPlayer] = [:]
    private var gripHapticTestActiveSlots: Set<Int> = []
    private var gripHapticTestGeneration: [Int: Int] = [:]
    private var motionFallbackStates: [Int: MotionFallbackState] = [:]
    private var lightColors: [Int: RGBColor] = [:]
    private var pendingIncomingColors: [Int: RGBColor] = [:]
    private var scheduledIncomingColorSlots: Set<Int> = []
    private var pendingPreview: [String: Float] = [:]
    private var totalSampledFrames = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        midiEnabled = defaults.object(forKey: "midiEnabled") as? Bool ?? true
        midiMotionEnabled = defaults.object(forKey: "midiMotionEnabled") as? Bool ?? false
        extendedMotionOSCEnabled = defaults.object(forKey: "extendedMotionOSCEnabled") as? Bool ?? false
        hapticsOSCEnabled = defaults.object(forKey: "hapticsOSCEnabled") as? Bool ?? true
        targetIP = defaults.string(forKey: "targetIP") ?? "127.0.0.1"
        let legacyPort = defaults.string(forKey: "targetPort")
        targetPort1 = defaults.string(forKey: "targetPort1") ?? ((legacyPort != nil && legacyPort != "9999") ? legacyPort! : "9991")
        targetPort2 = defaults.string(forKey: "targetPort2") ?? "9992"
        oscReceivePort1 = defaults.string(forKey: "oscReceivePort1") ?? "9993"
        oscReceivePort2 = defaults.string(forKey: "oscReceivePort2") ?? "9994"
        for slot in 1...2 {
            for side in ["l2", "r2"] {
                let key = "adaptiveTrigger.\(slot).\(side)"
                adaptiveTriggerSettings["\(slot).\(side)"] = AdaptiveTriggerSettings(
                    mode: defaults.object(forKey: "\(key).mode") as? Int ?? 0,
                    strength: defaults.object(forKey: "\(key).strength") as? Float ?? 0.5,
                    strength2: defaults.object(forKey: "\(key).strength2") as? Float ?? 0.5,
                    start: defaults.object(forKey: "\(key).start") as? Float ?? 0.2,
                    end: defaults.object(forKey: "\(key).end") as? Float ?? 0.8,
                    frequency: defaults.object(forKey: "\(key).frequency") as? Float ?? 0.5,
                    period: defaults.object(forKey: "\(key).period") as? Float ?? 0.5
                )
            }
        }
        inputSettings = [1: loadInputSettings(slot: 1), 2: loadInputSettings(slot: 2)]
        lightColors[1] = loadLightColor(slot: 1)
        lightColors[2] = loadLightColor(slot: 2)
        controllerStatuses = (1...2).map { slot in
            ControllerSlotStatus(slot: slot, isConnected: false, name: "等待連線…", batteryLevel: nil, batteryState: nil, supportsLight: nil, supportsHaptics: nil, lightColor: lightColor(forSlot: slot))
        }

        for slot in 1...2 {
            oscClients[slot]?.onStatusChange = { [weak self] message in
                Task { @MainActor [weak self] in
                    if slot == 1 { self?.networkStatus1 = message } else { self?.networkStatus2 = message }
                }
            }
            oscReceivers[slot]?.onStatusChange = { [weak self] message in
                Task { @MainActor [weak self] in
                    if slot == 1 { self?.oscReceiveStatus1 = message } else { self?.oscReceiveStatus2 = message }
                }
            }
            oscReceivers[slot]?.onMessages = { [weak self] messages in
                Task { @MainActor [weak self] in
                    for message in messages {
                        self?.handleIncomingOSC(message, slot: slot)
                    }
                }
            }
        }
        updateDestination()
        updateReceiver(slot: 1)
        updateReceiver(slot: 2)
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logAdaptiveTriggerState(reason: "app-became-active")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.reapplyAdaptiveTriggers(force: true)
                        self?.logAdaptiveTriggerState(reason: "active-plus-250ms")
                    }
                }
            }
        })
        // GameController turns off its reported adaptive-trigger mode as the
        // app loses focus. Reassert it once through raw HID after that write.
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logAdaptiveTriggerState(reason: "app-resigned-active")
                self.reapplyAdaptiveTriggers(force: true, activeOnly: true)
                // One report is enough; repeated writes only add traffic and
                // can compete with other output changes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    Task { @MainActor [weak self] in self?.applyBackgroundAdaptiveTriggers() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    Task { @MainActor [weak self] in self?.logAdaptiveTriggerState(reason: "background-plus-250ms") }
                }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileControllers()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    Task { @MainActor [weak self] in self?.reconcileControllers() }
                }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] notification in
            let disconnected = notification.object as? GCController
            Task { @MainActor [weak self] in self?.reconcileControllers(excluding: disconnected) }
        })
        GCController.startWirelessControllerDiscovery(completionHandler: {})
        reconcileControllers()
    }

    deinit {
        sampleTimer?.invalidate()
        statusTimer?.invalidate()
        previewTimer?.invalidate()
        hidMappingRetryTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    private func loadInputSettings(slot: Int) -> ControllerInputSettings {
        let legacyLeft = defaults.object(forKey: "deadzoneL") as? Double ?? 0.05
        let legacyRight = defaults.object(forKey: "deadzoneR") as? Double ?? 0.05
        let axes = ["lx", "ly", "rx", "ry", "accelX", "accelY", "accelZ", "gyroX", "gyroY", "gyroZ"]
        var inverted = Set<String>()
        for axis in axes {
            let legacyKey = legacyInversionKey(for: axis)
            let fallback = defaults.object(forKey: legacyKey) as? Bool ?? axis.hasPrefix("gyro")
            if defaults.object(forKey: "controller.\(slot).invert.\(axis)") as? Bool ?? fallback {
                inverted.insert(axis)
            }
        }
        return ControllerInputSettings(
            leftDeadzone: defaults.object(forKey: "controller.\(slot).deadzoneL") as? Double ?? legacyLeft,
            rightDeadzone: defaults.object(forKey: "controller.\(slot).deadzoneR") as? Double ?? legacyRight,
            invertedAxes: inverted
        )
    }

    private func legacyInversionKey(for axis: String) -> String {
        switch axis {
        case "lx": "invertLX"
        case "ly": "invertLY"
        case "rx": "invertRX"
        case "ry": "invertRY"
        case "accelX": "invertAccelX"
        case "accelY": "invertAccelY"
        case "accelZ": "invertAccelZ"
        case "gyroX": "invertGyroX"
        case "gyroY": "invertGyroY"
        default: "invertGyroZ"
        }
    }

    func deadzone(slot: Int, stick: String) -> Double {
        let settings = inputSettings[slot]
        return stick == "right" ? settings?.rightDeadzone ?? 0.05 : settings?.leftDeadzone ?? 0.05
    }

    func setDeadzone(_ value: Double, slot: Int, stick: String) {
        guard (1...2).contains(slot) else { return }
        var settings = inputSettings[slot] ?? loadInputSettings(slot: slot)
        let value = min(max(value, 0), 0.5)
        if stick == "right" { settings.rightDeadzone = value }
        else { settings.leftDeadzone = value }
        inputSettings[slot] = settings
        save("controller.\(slot).deadzone\(stick == "right" ? "R" : "L")", value)
    }

    func isAxisInverted(slot: Int, axis: String) -> Bool {
        inputSettings[slot]?.invertedAxes.contains(axis) ?? false
    }

    func setAxisInverted(_ inverted: Bool, slot: Int, axis: String) {
        guard (1...2).contains(slot) else { return }
        var settings = inputSettings[slot] ?? loadInputSettings(slot: slot)
        if inverted { settings.invertedAxes.insert(axis) }
        else { settings.invertedAxes.remove(axis) }
        inputSettings[slot] = settings
        save("controller.\(slot).invert.\(axis)", inverted)
    }

    private func updateDestination() {
        oscClients[1]?.configure(host: targetIP, port: UInt16(targetPort1.trimmingCharacters(in: .whitespacesAndNewlines)))
        oscClients[2]?.configure(host: targetIP, port: UInt16(targetPort2.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func updateReceiver(slot: Int) {
        let port = slot == 1 ? oscReceivePort1 : oscReceivePort2
        oscReceivers[slot]?.configure(port: UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func handleIncomingOSC(_ message: IncomingOSCMessage, slot: Int) {
        if handleAdaptiveTriggerOSC(message, slot: slot) { return }
        guard message.values.allSatisfy({ $0.isFinite }), let value = message.values.first else { return }
        if handleGripHapticOSC(message, slot: slot, value: value) { return }
        let previous = pendingIncomingColors[slot] ?? lightColor(forSlot: slot)
        let color: RGBColor
        switch message.address {
        case "/led/rgb" where message.values.count >= 3:
            color = RGBColor(red: message.values[0], green: message.values[1], blue: message.values[2])
        case "/led/r":
            color = RGBColor(red: value, green: previous.green, blue: previous.blue)
        case "/led/g":
            color = RGBColor(red: previous.red, green: value, blue: previous.blue)
        case "/led/b":
            color = RGBColor(red: previous.red, green: previous.green, blue: value)
        case "/haptic/pulse":
            guard hapticsOSCEnabled else { return }
            let isActive = value > 0
            if isActive && hapticTriggerActive[slot] != true {
                playHaptic(slot: slot, intensity: value)
            }
            hapticTriggerActive[slot] = isActive
            return
        default:
            return
        }
        pendingIncomingColors[slot] = boundedColor(color)
        if slot == 1 { oscReceiveStatus1 = "已接收燈色 · \(message.address)" }
        else { oscReceiveStatus2 = "已接收燈色 · \(message.address)" }

        // Coalesce RGB component messages arriving in the same main-run-loop turn.
        // This keeps the full incoming detail while issuing one complete light update.
        guard scheduledIncomingColorSlots.insert(slot).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledIncomingColorSlots.remove(slot)
                guard let latestColor = self.pendingIncomingColors.removeValue(forKey: slot) else { return }
                self.lightColors[slot] = latestColor
                if let controller = self.controllersBySlot[slot] {
                    self.applyLightColor(latestColor, to: controller)
                }
                self.refreshControllerStatuses()
            }
        }
    }

    private func boundedColor(_ color: RGBColor) -> RGBColor {
        RGBColor(
            red: min(max(color.red, 0), 1),
            green: min(max(color.green, 0), 1),
            blue: min(max(color.blue, 0), 1)
        )
    }

    private func loadLightColor(slot: Int) -> RGBColor? {
        let red = defaults.object(forKey: "lightColor.\(slot).red") as? Double
        let green = defaults.object(forKey: "lightColor.\(slot).green") as? Double
        let blue = defaults.object(forKey: "lightColor.\(slot).blue") as? Double
        guard let red, let green, let blue else { return nil }
        return RGBColor(red: Float(red), green: Float(green), blue: Float(blue))
    }

    private func lightColor(forSlot slot: Int) -> RGBColor {
        lightColors[slot] ?? (slot == 1
            ? RGBColor(red: 0.12, green: 0.56, blue: 0.96)
            : RGBColor(red: 0.96, green: 0.20, blue: 0.40))
    }

    func setLightColor(_ color: RGBColor, forSlot slot: Int, persist: Bool = true) {
        guard (1...2).contains(slot) else { return }
        let bounded = boundedColor(color)
        lightColors[slot] = bounded
        if persist {
            save("lightColor.\(slot).red", Double(bounded.red))
            save("lightColor.\(slot).green", Double(bounded.green))
            save("lightColor.\(slot).blue", Double(bounded.blue))
        }
        if let controller = controllersBySlot[slot] { applyLightColor(bounded, to: controller) }
        refreshControllerStatuses()
    }

    private func applyLightColor(_ color: RGBColor, to controller: GCController) {
        controller.light?.color = GCColor(red: color.red, green: color.green, blue: color.blue)
    }

    func assignController(fromSlot: Int, toSlot: Int) {
        guard (1...2).contains(fromSlot), (1...2).contains(toSlot), fromSlot != toSlot,
              let movingController = controllersBySlot[fromSlot] else { return }

        let displacedController = controllersBySlot[toSlot]
        sendNeutralControlState(slot: fromSlot)
        sendNeutralControlState(slot: toSlot)
        if midiEnabled {
            midiOutput.sendNeutral(channel: UInt8(fromSlot))
            midiOutput.sendNeutral(channel: UInt8(toSlot))
        }

        controllersBySlot[toSlot] = movingController
        movingController.playerIndex = playerIndex(forSlot: toSlot)
        motionFallbackStates[toSlot] = MotionFallbackState()
        applyStoredAdaptiveTriggers(slot: toSlot)
        applyLightColor(lightColor(forSlot: toSlot), to: movingController)
        if let displacedController {
            controllersBySlot[fromSlot] = displacedController
            displacedController.playerIndex = playerIndex(forSlot: fromSlot)
            motionFallbackStates[fromSlot] = MotionFallbackState()
            applyStoredAdaptiveTriggers(slot: fromSlot)
            applyLightColor(lightColor(forSlot: fromSlot), to: displacedController)
        } else {
            controllersBySlot.removeValue(forKey: fromSlot)
            motionFallbackStates.removeValue(forKey: fromSlot)
        }

        midiOutput.resetStateCache(channel: UInt8(fromSlot))
        midiOutput.resetStateCache(channel: UInt8(toSlot))
        for slot in 1...2 {
            stopHapticStreams(slot: slot)
            hapticEngines[slot]?.stop(completionHandler: nil)
            hapticEngines.removeValue(forKey: slot)
            hapticPlayers.removeValue(forKey: slot)
            hapticTriggerActive.removeValue(forKey: slot)
        }
        for (slot, controller) in controllersBySlot {
            configureHaptics(for: controller, slot: slot)
        }
        sendStatus(for: movingController, slot: toSlot)
        if let displacedController { sendStatus(for: displacedController, slot: fromSlot) }
        refreshControllerStatuses()
        sample()
    }

    private func playerIndex(forSlot slot: Int) -> GCControllerPlayerIndex {
        slot == 1 ? .index1 : .index2
    }

    func playHapticTest(slot: Int) {
        playHaptic(slot: slot, intensity: 0.75)
    }

    /// Runs the same sustained-haptics path as OSC, without depending on a
    /// TouchDesigner sender. This makes it easy to tell playback problems from
    /// OSC routing problems.
    func playGripHapticTest(slot: Int) {
        guard hapticsOSCEnabled else { return }
        let generation = (gripHapticTestGeneration[slot] ?? 0) + 1
        gripHapticTestGeneration[slot] = generation
        gripHapticTestActiveSlots.insert(slot)
        setGripHaptic(intensity: 0.7, slot: slot)
        scheduleGripHapticTestStep(slot: slot, generation: generation, after: 1.5) {
            $0.setGripHaptic(intensity: 0, slot: slot)
        }
    }

    private func scheduleGripHapticTestStep(slot: Int, generation: Int, after delay: TimeInterval, _ action: @escaping (PS5Manager) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.gripHapticTestGeneration[slot] == generation else { return }
                action(self)
                self.gripHapticTestActiveSlots.remove(slot)
            }
        }
    }

    func playAdaptiveTriggerTest(slot: Int, side: String) {
        setAdaptiveTriggerSettings(
            AdaptiveTriggerSettings(mode: 2, strength: 0.65, start: 0.2, end: 0.8, frequency: adaptiveTriggerSettings(for: slot, side: side).frequency),
            slot: slot,
            side: side
        )
    }

    func stopAdaptiveTrigger(slot: Int, side: String) {
        var settings = adaptiveTriggerSettings(for: slot, side: side)
        settings.mode = 0
        setAdaptiveTriggerSettings(settings, slot: slot, side: side)
    }

    func reapplyAdaptiveTriggers(force: Bool = false, activeOnly: Bool = false) {
        for (slot, controller) in controllersBySlot {
            guard let gamepad = controller.extendedGamepad as? GCDualSenseGamepad else { continue }
            for side in ["l2", "r2"] {
                let settings = adaptiveTriggerSettings(for: slot, side: side)
                if activeOnly && settings.mode == 0 { continue }
                let trigger = side == "l2" ? gamepad.leftTrigger : gamepad.rightTrigger
                // The trigger's mode reports hardware state asynchronously.
                // Don't resend active effects from status polling: each command
                // replaces the controller's current adaptive-trigger effect.
                if force || trigger.mode.rawValue != settings.mode {
                    applyAdaptiveTrigger(settings, slot: slot, side: side)
                }
            }
        }
        if adaptiveTriggerSettings.values.contains(where: { $0.mode >= 4 }) {
            applyBackgroundAdaptiveTriggers(force: true)
        }
    }

    private func logAdaptiveTriggerState(reason: String) {
        let active = NSApplication.shared.isActive
        for (slot, controller) in controllersBySlot.sorted(by: { $0.key < $1.key }) {
            guard let gamepad = controller.extendedGamepad as? GCDualSenseGamepad else { continue }
            for side in ["l2", "r2"] {
                let trigger = side == "l2" ? gamepad.leftTrigger : gamepad.rightTrigger
                let configured = adaptiveTriggerSettings(for: slot, side: side)
                print("[DualSenseOM TriggerDiag] event=\(reason) appActive=\(active) slot=\(slot) side=\(side) configuredMode=\(configured.mode) reportedMode=\(trigger.mode.rawValue) status=\(trigger.status.rawValue) arm=\(String(format: "%.3f", trigger.armPosition))")
            }
        }
    }

    func adaptiveTriggerSettings(for slot: Int, side: String) -> AdaptiveTriggerSettings {
        adaptiveTriggerSettings["\(slot).\(side)"] ?? AdaptiveTriggerSettings()
    }

    func setAdaptiveTriggerParameter(_ parameter: String, value: Double, slot: Int, side: String) {
        var settings = adaptiveTriggerSettings(for: slot, side: side)
        let bounded = Float(min(max(value, 0), 1))
        switch parameter {
        case "mode": settings.mode = min(max(Int(value.rounded()), 0), 6)
        case "start": settings.start = min(bounded, 0.98)
        case "end": settings.end = max(bounded, settings.start + 0.01)
        case "strength": settings.strength = bounded
        case "strength2": settings.strength2 = bounded
        // DualSense trigger vibration encodes frequency as an 8-bit Hz value
        // (0...255). GameController accepts the normalized equivalent.
        case "frequency":
            let hertz = min(max(value, 0), 255).rounded()
            settings.frequency = Float(hertz / 255)
        case "period": settings.period = bounded
        default: return
        }
        if settings.end <= settings.start { settings.end = min(settings.start + 0.01, 1) }
        setAdaptiveTriggerSettings(settings, slot: slot, side: side)
    }

    private func setAdaptiveTriggerSettings(_ settings: AdaptiveTriggerSettings, slot: Int, side: String) {
        guard (1...2).contains(slot), ["l2", "r2"].contains(side) else { return }
        let key = "\(slot).\(side)"
        guard adaptiveTriggerSettings[key] != settings else { return }
        adaptiveTriggerSettings[key] = settings
        let defaultsKey = "adaptiveTrigger.\(key)"
        defaults.set(settings.mode, forKey: "\(defaultsKey).mode")
        defaults.set(settings.strength, forKey: "\(defaultsKey).strength")
        defaults.set(settings.start, forKey: "\(defaultsKey).start")
        defaults.set(settings.end, forKey: "\(defaultsKey).end")
        defaults.set(settings.frequency, forKey: "\(defaultsKey).frequency")
        defaults.set(settings.strength2, forKey: "\(defaultsKey).strength2")
        defaults.set(settings.period, forKey: "\(defaultsKey).period")
        applyAdaptiveTrigger(settings, slot: slot, side: side)
        if settings.mode >= 4 || !NSApplication.shared.isActive {
            applyBackgroundAdaptiveTriggers(slots: [slot], force: true)
        }
    }

    private func applyBackgroundAdaptiveTriggers(slots selectedSlots: Set<Int>? = nil, force: Bool = false) {
        var targets: [String: [String: AdaptiveTriggerSettings]] = [:]
        for (slot, controller) in controllersBySlot {
            guard selectedSlots == nil || selectedSlots!.contains(slot),
                  let identity = hidIdentityByController[ObjectIdentifier(controller)] else { continue }
            targets[identity] = [
                "l2": adaptiveTriggerSettings(for: slot, side: "l2"),
                "r2": adaptiveTriggerSettings(for: slot, side: "r2")
            ]
        }
        DualSenseHIDTriggerWriter.shared.applyBackground(targets: targets, force: force)
    }

    func extendedMotionDescription(slot: Int) -> String {
        guard let motion = controllersBySlot[slot]?.motion else { return "等待手把體感資料" }
        let attitude = motion.hasAttitude ? "原生姿態" : "陀螺儀相對姿態估算"
        let acceleration = motion.hasGravityAndUserAcceleration ? "原生重力分離" : "加速度低通估算重力／使用者加速度"
        return "手把 \(slot)：\(attitude) · \(acceleration)"
    }

    private func extendedMotionValues(_ motion: GCMotion, slot: Int) -> [(String, Float)] {
        var state = motionFallbackStates[slot] ?? MotionFallbackState()
        let now = ProcessInfo.processInfo.systemUptime
        let deltaTime = min(max(now - (state.lastTime ?? now), 0), 0.1)
        state.lastTime = now

        if motion.hasAttitude {
            let attitude = motion.attitude
            state.qx = attitude.x; state.qy = attitude.y; state.qz = attitude.z; state.qw = attitude.w
        } else {
            let rate = motion.rotationRate
            let speed = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            let angle = speed * deltaTime
            if speed > 0.000001 && deltaTime > 0 {
                let scale = sin(angle * 0.5) / speed
                let dx = rate.x * scale, dy = rate.y * scale, dz = rate.z * scale, dw = cos(angle * 0.5)
                let x = state.qw * dx + state.qx * dw + state.qy * dz - state.qz * dy
                let y = state.qw * dy - state.qx * dz + state.qy * dw + state.qz * dx
                let z = state.qw * dz + state.qx * dy - state.qy * dx + state.qz * dw
                let w = state.qw * dw - state.qx * dx - state.qy * dy - state.qz * dz
                let norm = max(sqrt(x * x + y * y + z * z + w * w), 0.000001)
                state.qx = x / norm; state.qy = y / norm; state.qz = z / norm; state.qw = w / norm
            }
        }

        let gravity: (Double, Double, Double)
        let userAcceleration: (Double, Double, Double)
        if motion.hasGravityAndUserAcceleration {
            gravity = (motion.gravity.x, motion.gravity.y, motion.gravity.z)
            userAcceleration = (motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z)
        } else {
            let acceleration = motion.acceleration
            if state.gravityX == nil {
                state.gravityX = acceleration.x; state.gravityY = acceleration.y; state.gravityZ = acceleration.z
            } else if deltaTime > 0 {
                let blend = 1 - exp(-deltaTime / 0.45)
                state.gravityX! += blend * (acceleration.x - state.gravityX!)
                state.gravityY! += blend * (acceleration.y - state.gravityY!)
                state.gravityZ! += blend * (acceleration.z - state.gravityZ!)
            }
            let gx = state.gravityX ?? 0, gy = state.gravityY ?? 0, gz = state.gravityZ ?? 0
            gravity = (gx, gy, gz)
            userAcceleration = (acceleration.x - gx, acceleration.y - gy, acceleration.z - gz)
        }

        motionFallbackStates[slot] = state
        return [
            ("attitude/x", Float(state.qx)), ("attitude/y", Float(state.qy)), ("attitude/z", Float(state.qz)), ("attitude/w", Float(state.qw)),
            ("gravity/x", Float(gravity.0)), ("gravity/y", Float(gravity.1)), ("gravity/z", Float(gravity.2)),
            ("useracc/x", Float(userAcceleration.0)), ("useracc/y", Float(userAcceleration.1)), ("useracc/z", Float(userAcceleration.2))
        ]
    }

    private func handleAdaptiveTriggerOSC(_ message: IncomingOSCMessage, slot: Int) -> Bool {
        let parts = message.address.split(separator: "/").map(String.init)
        guard (parts.count == 3 || parts.count == 4), parts[0] == "trigger", ["l2", "r2"].contains(parts[1]),
              parts[2] == "mode" || (parts.count == 3 && ["strength", "strength2", "start", "end", "frequency", "period", "off"].contains(parts[2])) else { return false }
        guard hapticsOSCEnabled else { return true }

        let side = parts[1]
        var settings = adaptiveTriggerSettings(for: slot, side: side)
        if parts[2] == "mode" {
            let names = ["none": 0, "off": 0, "trigger": 1, "feedback": 1, "weapon": 2, "vibration": 3, "bow": 4, "galloping": 5, "machine": 6]
            let addressName = parts.count == 4 ? parts[3].lowercased() : nil
            if let name = (addressName ?? message.strings.first)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               let mode = names[name] {
                settings.mode = mode
            } else if let value = message.values.first, value.isFinite {
                // Keep numeric values accepted for older TouchDesigner networks.
                settings.mode = min(max(Int(value.rounded()), 0), 6)
            } else {
                return true
            }
            setAdaptiveTriggerSettings(settings, slot: slot, side: side)
            return true
        }

        guard message.values.allSatisfy({ $0.isFinite }), let value = message.values.first else { return true }
        switch parts[2] {
        case "strength": settings.strength = min(max(value, 0), 1)
        case "strength2": settings.strength2 = min(max(value, 0), 1)
        case "start": settings.start = min(max(value, 0), 0.98)
        case "end": settings.end = min(max(value, settings.start + 0.01), 1)
        case "frequency": settings.frequency = min(max(value.rounded(), 0), 255) / 255
        case "period": settings.period = min(max(value, 0), 1)
        case "off": settings.mode = 0
        default: return false
        }
        if settings.end <= settings.start { settings.end = min(settings.start + 0.01, 1) }
        setAdaptiveTriggerSettings(settings, slot: slot, side: side)
        return true
    }

    private func handleGripHapticOSC(_ message: IncomingOSCMessage, slot: Int, value: Float) -> Bool {
        let parts = message.address.split(separator: "/").map(String.init)
        guard parts == ["haptic"] else { return false }
        guard hapticsOSCEnabled else { return true }
        guard !gripHapticTestActiveSlots.contains(slot) else { return true }
        setGripHaptic(intensity: value, slot: slot)
        return true
    }

    private func setGripHaptic(intensity rawValue: Float, slot: Int) {
        let intensity = min(max(rawValue, 0), 1)
        guard intensity > 0 else {
            stopGripHapticStream(slot: slot)
            return
        }
        guard let engine = hapticEngines[slot] else {
            return
        }
        do {
            if let player = gripHapticPlayers[slot] {
                try player.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)
                ], atTime: CHHapticTimeImmediate)
            } else {
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
                    ],
                    relativeTime: 0,
                    duration: TimeInterval(GCHapticDurationInfinite)
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                gripHapticPlayers[slot] = player
            }
        } catch {
            stopGripHapticStream(slot: slot)
            print("[DualSenseOM Haptics] stream failed slot=\(slot): \(error.localizedDescription)")
        }
    }

    private func stopGripHapticStream(slot: Int) {
        if let player = gripHapticPlayers.removeValue(forKey: slot) {
            do { try player.stop(atTime: CHHapticTimeImmediate) }
            catch { print("[DualSenseOM Haptics] stop failed slot=\(slot): \(error.localizedDescription)") }
        }
    }

    private func stopGripHapticStreams(slot: Int? = nil) {
        let slots = gripHapticPlayers.keys.filter { slot == nil || $0 == slot }
        for gripSlot in slots { stopGripHapticStream(slot: gripSlot) }
    }

    private func stopHapticStreams(slot: Int? = nil) {
        stopGripHapticStreams(slot: slot)
    }

    private func applyAdaptiveTrigger(_ settings: AdaptiveTriggerSettings, slot: Int, side: String) {
        guard let gamepad = controllersBySlot[slot]?.extendedGamepad as? GCDualSenseGamepad else { return }
        // These effects have no GameController equivalent; the HID report below owns them.
        guard settings.mode <= 3 else { return }
        let trigger = side == "l2" ? gamepad.leftTrigger : gamepad.rightTrigger
        switch settings.mode {
        case 1:
            trigger.setModeFeedbackWithStartPosition(settings.start, resistiveStrength: settings.strength)
        case 2:
            trigger.setModeWeaponWithStartPosition(settings.start, endPosition: settings.end, resistiveStrength: settings.strength)
        case 3:
            trigger.setModeVibrationWithStartPosition(settings.start, amplitude: settings.strength, frequency: settings.frequency)
        default:
            trigger.setModeOff()
        }
    }

    private func applyStoredAdaptiveTriggers(slot: Int) {
        for side in ["l2", "r2"] {
            applyAdaptiveTrigger(adaptiveTriggerSettings["\(slot).\(side)"] ?? AdaptiveTriggerSettings(), slot: slot, side: side)
        }
    }

    private func playHaptic(slot: Int, intensity: Float) {
        guard let engine = hapticEngines[slot] else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: min(max(intensity, 0.05), 1)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            hapticPlayers[slot] = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            hapticPlayers.removeValue(forKey: slot)
            hapticTriggerActive.removeValue(forKey: slot)
        }
    }

    private func configureHaptics(for controller: GCController, slot: Int) {
        stopHapticStreams(slot: slot)
        hapticEngines[slot]?.stop(completionHandler: nil)
        hapticEngines.removeValue(forKey: slot)
        hapticPlayers.removeValue(forKey: slot)
        guard let haptics = controller.haptics else { return }
        if let engine = haptics.createEngine(withLocality: .handles) {
            do {
                try engine.start()
                hapticEngines[slot] = engine
            } catch {
                hapticEngines.removeValue(forKey: slot)
            }
        }
    }

    private func reconcileControllers(excluding disconnected: GCController? = nil) {
        let discovered = GCController.controllers().filter {
            $0 !== disconnected && $0.extendedGamepad is GCDualSenseGamepad
        }

        for slot in Array(controllersBySlot.keys).sorted() {
            guard let existing = controllersBySlot[slot], !discovered.contains(where: { $0 === existing }) else { continue }
            stopHapticStreams(slot: slot)
            (existing.extendedGamepad as? GCDualSenseGamepad)?.leftTrigger.setModeOff()
            (existing.extendedGamepad as? GCDualSenseGamepad)?.rightTrigger.setModeOff()
            existing.motion?.sensorsActive = false
            hapticEngines[slot]?.stop(completionHandler: nil)
            hapticEngines.removeValue(forKey: slot)
            gripHapticPlayers.removeValue(forKey: slot)
            hapticPlayers.removeValue(forKey: slot)
            hapticTriggerActive.removeValue(forKey: slot)
            hidIdentityByController.removeValue(forKey: ObjectIdentifier(existing))
            controllersBySlot.removeValue(forKey: slot)
            motionFallbackStates.removeValue(forKey: slot)
            sendNeutralControlState(slot: slot)
            if midiEnabled { midiOutput.sendNeutral(channel: UInt8(slot)) }
            pendingPreview[previewStatusKey("connected", slot: slot)] = 0
            pendingPreview.removeValue(forKey: previewStatusKey("battery", slot: slot))
            pendingPreview[previewStatusKey("battery_state", slot: slot)] = 0
            pendingPreview[previewStatusKey("charging", slot: slot)] = -1
            oscClients[slot]?.send([
                OSCMessage(address: statusAddress("connected", slot: slot), value: 0),
                OSCMessage(address: statusAddress("battery_state", slot: slot), value: 0),
                OSCMessage(address: statusAddress("charging", slot: slot), value: -1)
            ])
        }

        for controller in discovered where !controllersBySlot.values.contains(where: { $0 === controller }) {
            let preferredSlot: Int?
            switch controller.playerIndex {
            case .index1: preferredSlot = 1
            case .index2: preferredSlot = 2
            default: preferredSlot = nil
            }
            let slot = preferredSlot.flatMap { controllersBySlot[$0] == nil ? $0 : nil }
                ?? (1...2).first(where: { controllersBySlot[$0] == nil })
            guard let slot else { break }
            controllersBySlot[slot] = controller
            motionFallbackStates[slot] = MotionFallbackState()
            controller.playerIndex = playerIndex(forSlot: slot)
            applyStoredAdaptiveTriggers(slot: slot)
            controller.motion?.sensorsActive = true
            configureHaptics(for: controller, slot: slot)
            midiOutput.resetStateCache(channel: UInt8(slot))
            if let selectedColor = lightColors[slot], let light = controller.light {
                light.color = GCColor(red: selectedColor.red, green: selectedColor.green, blue: selectedColor.blue)
            } else if let currentColor = controller.light?.color {
                lightColors[slot] = RGBColor(red: currentColor.red, green: currentColor.green, blue: currentColor.blue)
            }
            sendStatus(for: controller, slot: slot)
        }

        updateHIDTriggerMappings(discovered: discovered)

        refreshControllerStatuses()
        if controllersBySlot.isEmpty {
            stopTimers()
            pendingPreview[previewStatusKey("connected", slot: 1)] = 0
            pendingPreview[previewStatusKey("connected", slot: 2)] = 0
            preview = pendingPreview
            sampledFrames = totalSampledFrames
        } else {
            if sampleTimer == nil { startTimers() }
            sample()
        }
    }

    private func updateHIDTriggerMappings(discovered: [GCController]) {
        let connectedIDs = DualSenseHIDTriggerWriter.shared.connectedDeviceIdentities()
        guard !connectedIDs.isEmpty else {
            hidTriggerStatus = discovered.isEmpty ? "等待手把" : "等待 HID 裝置"
            print("[DualSenseOM HIDTrigger] mapping pending: no physical HID device found")
            if discovered.isEmpty { cancelHIDMappingRetry() }
            else { scheduleHIDMappingRetry() }
            return
        }

        let activeControllerIDs = Set(discovered.map(ObjectIdentifier.init))
        hidIdentityByController = hidIdentityByController.filter { activeControllerIDs.contains($0.key) }
        let availableIDs = Set(connectedIDs)
        hidIdentityByController = hidIdentityByController.filter { availableIDs.contains($0.value) }

        let mappedIDs = Set(hidIdentityByController.values)
        let unpairedControllers = discovered.filter { hidIdentityByController[ObjectIdentifier($0)] == nil }
        let unpairedHIDIDs = Array(availableIDs.subtracting(mappedIDs))

        if unpairedControllers.count == 1 && unpairedHIDIDs.count == 1 {
            let controller = unpairedControllers[0]
            let identity = unpairedHIDIDs[0]
            hidIdentityByController[ObjectIdentifier(controller)] = identity
            let slot = controllersBySlot.first(where: { $0.value === controller })?.key ?? 0
            print("[DualSenseOM HIDTrigger] mapped slot=\(slot) HID device=…\(identity.suffix(4))")
        } else if !unpairedControllers.isEmpty || !unpairedHIDIDs.isEmpty {
            print("[DualSenseOM HIDTrigger] mapping pending: \(unpairedControllers.count) unpaired GameController(s), \(unpairedHIDIDs.count) unpaired HID device(s); connect controllers one at a time")
        }

        if discovered.isEmpty {
            hidTriggerStatus = "等待手把"
            cancelHIDMappingRetry()
        } else if hidIdentityByController.count == discovered.count {
            hidTriggerStatus = "HID 板機就緒 · \(discovered.count) 支"
            cancelHIDMappingRetry()
        } else if discovered.count > 1 && hidIdentityByController.isEmpty {
            hidTriggerStatus = "HID 配對待確認 · 逐支重連"
            scheduleHIDMappingRetry()
        } else {
            hidTriggerStatus = "HID 配對中 · \(hidIdentityByController.count)/\(discovered.count)"
            scheduleHIDMappingRetry()
        }
    }

    /// USB and Bluetooth HID devices can appear after GameController posts its
    /// connection notification. Retry in the background with capped backoff
    /// so changing tabs is never required to refresh the HID mapping.
    private func scheduleHIDMappingRetry() {
        guard hidMappingRetryTimer == nil else { return }
        let delays: [TimeInterval] = [0.25, 0.5, 1, 2, 3]
        let delay = delays[min(hidMappingRetryAttempt, delays.count - 1)]
        hidMappingRetryAttempt += 1
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hidMappingRetryTimer = nil
                self.reconcileControllers()
            }
        }
        hidMappingRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelHIDMappingRetry() {
        hidMappingRetryTimer?.invalidate()
        hidMappingRetryTimer = nil
        hidMappingRetryAttempt = 0
    }

    private func refreshControllerStatuses() {
        controllerStatuses = (1...2).map { slot in
            let controller = controllersBySlot[slot]
            return ControllerSlotStatus(
                slot: slot,
                isConnected: controller != nil,
                name: controller?.vendorName ?? (controller == nil ? "等待連線…" : "DualSense"),
                batteryLevel: controller?.battery?.batteryLevel,
                batteryState: controller.flatMap { batteryState(for: $0) },
                supportsLight: controller.map { $0.light != nil },
                supportsHaptics: controller == nil ? nil : hapticEngines[slot] != nil,
                lightColor: lightColor(forSlot: slot)
            )
        }
        isConnected = !controllersBySlot.isEmpty
        controllerName = controllersBySlot.count > 1 ? "2 支 DualSense 已連線" : (controllersBySlot.values.first?.vendorName ?? (isConnected ? "DualSense" : "等待 DualSense 連線…"))
        batteryLevel = controllersBySlot[1]?.battery?.batteryLevel ?? controllersBySlot[2]?.battery?.batteryLevel
    }

    private func controlAddress(_ path: String, slot: Int) -> String {
        "/ds/c/" + path
    }

    private func statusAddress(_ path: String, slot: Int) -> String {
        "/ds/s/" + path
    }

    private func previewKey(_ path: String, slot: Int) -> String {
        slot == 1 ? "c/\(path)" : "\(slot)/c/\(path)"
    }

    private func previewStatusKey(_ path: String, slot: Int) -> String {
        slot == 1 ? "s/\(path)" : "\(slot)/s/\(path)"
    }

    private func sendNeutralControlState(slot: Int) {
        var paths = [
            "lx", "ly", "rx", "ry", "l2", "r2", "l1", "r1",
            "cross", "circle", "square", "triangle", "du", "dd", "dl", "dr",
            "options", "menu", "l3", "r3", "tclick",
            "t1/x", "t1/y", "t1/touch", "t2/x", "t2/y", "t2/touch",
            "acc/x", "acc/y", "acc/z", "gyro/x", "gyro/y", "gyro/z"
        ]
        if extendedMotionOSCEnabled {
            paths += ["attitude/x", "attitude/y", "attitude/z", "attitude/w", "gravity/x", "gravity/y", "gravity/z", "useracc/x", "useracc/y", "useracc/z"]
        }
        oscClients[slot]?.send(paths.map { OSCMessage(address: controlAddress($0, slot: slot), value: 0) })
        for path in paths { pendingPreview[previewKey(path, slot: slot)] = 0 }
    }

    private func sample() {
        guard !controllersBySlot.isEmpty else { return }
        for slot in controllersBySlot.keys.sorted() {
            guard let controller = controllersBySlot[slot],
                  let pad = controller.extendedGamepad as? GCDualSenseGamepad else { continue }
            var messages: [OSCMessage] = []
            sample(controller: controller, pad: pad, slot: slot, messages: &messages)
            totalSampledFrames += 1
            oscClients[slot]?.send(messages)
        }
    }

    private func sample(controller: GCController, pad: GCDualSenseGamepad, slot: Int, messages: inout [OSCMessage]) {
        var current: [String: Float] = [:]
        func put(_ path: String, _ value: Float) {
            messages.append(OSCMessage(address: controlAddress(path, slot: slot), value: value))
            current["c/\(path)"] = value
            pendingPreview[previewKey(path, slot: slot)] = value
        }
        func pressed(_ path: String, _ input: GCControllerButtonInput?) {
            if let input { put(path, input.isPressed ? 1 : 0) }
        }
        func sign(_ value: Float, inverted: Bool) -> Float { inverted ? -value : value }

        let left = StickDeadzone.apply(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value, deadzone: deadzone(slot: slot, stick: "left"))
        let right = StickDeadzone.apply(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value, deadzone: deadzone(slot: slot, stick: "right"))
        put("lx", sign(left.x, inverted: isAxisInverted(slot: slot, axis: "lx"))); put("ly", sign(left.y, inverted: isAxisInverted(slot: slot, axis: "ly")))
        put("rx", sign(right.x, inverted: isAxisInverted(slot: slot, axis: "rx"))); put("ry", sign(right.y, inverted: isAxisInverted(slot: slot, axis: "ry")))
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
        let p1Touched = max(abs(p1x), abs(p1y)) > 0.015
        let p2Touched = max(abs(p2x), abs(p2y)) > 0.015
        put("t1/x", p1Touched ? p1x : 0); put("t1/y", p1Touched ? p1y : 0); put("t1/touch", p1Touched ? 1 : 0)
        put("t2/x", p2Touched ? p2x : 0); put("t2/y", p2Touched ? p2y : 0); put("t2/touch", p2Touched ? 1 : 0)

        if let motion = controller.motion {
            put("acc/x", Float(motion.acceleration.x) * (isAxisInverted(slot: slot, axis: "accelX") ? -1 : 1))
            put("acc/y", Float(motion.acceleration.y) * (isAxisInverted(slot: slot, axis: "accelY") ? -1 : 1))
            put("acc/z", Float(motion.acceleration.z) * (isAxisInverted(slot: slot, axis: "accelZ") ? -1 : 1))
            put("gyro/x", Float(motion.rotationRate.x) * (isAxisInverted(slot: slot, axis: "gyroX") ? -1 : 1))
            put("gyro/y", Float(motion.rotationRate.y) * (isAxisInverted(slot: slot, axis: "gyroY") ? -1 : 1))
            put("gyro/z", Float(motion.rotationRate.z) * (isAxisInverted(slot: slot, axis: "gyroZ") ? -1 : 1))

            if extendedMotionOSCEnabled {
                for (path, value) in extendedMotionValues(motion, slot: slot) { put(path, value) }
            }
        }

        if midiEnabled { midiOutput.send(frame: current, includeMotion: midiMotionEnabled, channel: UInt8(slot)) }
    }

    private func sendStatus(for controller: GCController, slot: Int) {
        var status = [OSCMessage(address: statusAddress("connected", slot: slot), value: 1)]
        pendingPreview[previewStatusKey("connected", slot: slot)] = 1
        if let battery = controller.battery?.batteryLevel {
            if slot == 1 || batteryLevel == nil { batteryLevel = battery }
            status.append(OSCMessage(address: statusAddress("battery", slot: slot), value: battery))
            pendingPreview[previewStatusKey("battery", slot: slot)] = battery
        } else {
            pendingPreview.removeValue(forKey: previewStatusKey("battery", slot: slot))
        }
        let state = batteryState(for: controller) ?? .unknown
        status.append(OSCMessage(address: statusAddress("battery_state", slot: slot), value: Float(state.rawValue)))
        status.append(OSCMessage(address: statusAddress("charging", slot: slot), value: state.chargingOSCValue))
        pendingPreview[previewStatusKey("battery_state", slot: slot)] = Float(state.rawValue)
        pendingPreview[previewStatusKey("charging", slot: slot)] = state.chargingOSCValue
        oscClients[slot]?.send(status)
    }

    private func batteryState(for controller: GCController) -> ControllerBatteryState? {
        guard let battery = controller.battery else { return nil }
        switch battery.batteryState {
        case .unknown: return .unknown
        case .discharging: return .discharging
        case .charging: return .charging
        case .full: return .full
        @unknown default: return .unknown
        }
    }

    private func sendStatus() {
        for slot in controllersBySlot.keys.sorted() {
            if let controller = controllersBySlot[slot] { sendStatus(for: controller, slot: slot) }
        }
        refreshControllerStatuses()
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
        stopHapticStreams()
        var triggerOffTargets: [String: [String: AdaptiveTriggerSettings]] = [:]
        for (slot, controller) in controllersBySlot {
            controller.motion?.sensorsActive = false
            (controller.extendedGamepad as? GCDualSenseGamepad)?.leftTrigger.setModeOff()
            (controller.extendedGamepad as? GCDualSenseGamepad)?.rightTrigger.setModeOff()
            if let identity = hidIdentityByController[ObjectIdentifier(controller)] {
                triggerOffTargets[identity] = ["l2": AdaptiveTriggerSettings(), "r2": AdaptiveTriggerSettings()]
            }
            sendNeutralControlState(slot: slot)
            if midiEnabled { midiOutput.sendNeutral(channel: UInt8(slot)) }
            hapticEngines[slot]?.stop(completionHandler: nil)
        }
        // Clear any raw HID effect on a normal app exit so a trigger cannot
        // remain latched after the app closes.
        DualSenseHIDTriggerWriter.shared.applyBackground(targets: triggerOffTargets, force: true)
        stopTimers()
        for slot in 1...2 {
            oscClients[slot]?.send([OSCMessage(address: statusAddress("connected", slot: slot), value: 0)])
        }
    }
}

/// Raw HID output is limited to the two adaptive-trigger fields. All other
/// controller outputs continue to use GameController.
@MainActor
final class DualSenseHIDTriggerWriter {
    static let shared = DualSenseHIDTriggerWriter()

    private var bluetoothSequence: UInt8 = 0

    private init() {}

    /// Registry entry IDs let us address a specific live HID device without
    /// guessing from enumeration order or player index.
    func connectedDeviceIdentities() -> [String] {
        guard let manager = createManager() else { return [] }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        let identities = devices.compactMap { identity(of: $0) }
        return identities
    }

    /// Sends one output report per targeted controller, with L2 and R2
    /// combined. Calls are made only on a focus transition or a settings change.
    func applyBackground(targets: [String: [String: AdaptiveTriggerSettings]], force: Bool = false) {
        guard !targets.isEmpty, let manager = createManager() else {
            print("[DualSenseOM HIDTrigger] no target HID devices available")
            return
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let references = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            print("[DualSenseOM HIDTrigger] could not enumerate HID devices")
            return
        }

        var found = 0
        var sent = 0
        for reference in references {
            guard let identity = identity(of: reference), let settings = targets[identity] else { continue }
            found += 1
            let transport = (IOHIDDeviceGetProperty(reference, kIOHIDTransportKey as CFString) as? String ?? "").lowercased()
            guard transport == "usb" || transport == "bluetooth" else {
                print("[DualSenseOM HIDTrigger] unsupported transport \(transport)")
                continue
            }
            guard force || settings.values.contains(where: { $0.mode != 0 }) else { continue }
            guard IOHIDDeviceOpen(reference, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                print("[DualSenseOM HIDTrigger] could not open target device id=\(identity)")
                continue
            }

            let report = makeReport(transport: transport, settingsBySide: settings)
            let reportID: CFIndex = transport == "usb" ? 0x02 : 0x31
            let result = report.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(reference, kIOHIDReportTypeOutput, reportID,
                                     buffer.baseAddress!, CFIndex(buffer.count))
            }
            if result == kIOReturnSuccess {
                sent += 1
            } else {
                print("[DualSenseOM HIDTrigger] report failed id=\(identity) code=\(result)")
            }
            IOHIDDeviceClose(reference, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        if found != targets.count || sent != targets.count {
            print("[DualSenseOM HIDTrigger] target summary found=\(found)/\(targets.count) sent=\(sent)/\(targets.count)")
        }
    }

    private func createManager() -> IOHIDManager? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [[
            kIOHIDVendorIDKey as String: 0x054C,
            kIOHIDProductIDKey as String: 0x0CE6,
            "GCSyntheticDevice": false
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            print("[DualSenseOM HIDTrigger] could not open HID manager")
            return nil
        }
        return manager
    }

    private func identity(of device: IOHIDDevice) -> String? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { return nil }
        return String(registryID, radix: 16)
    }

    private func makeReport(transport: String, settingsBySide: [String: AdaptiveTriggerSettings]) -> [UInt8] {
        let isBluetooth = transport == "bluetooth"
        var report = [UInt8](repeating: 0, count: isBluetooth ? 78 : 63)
        report[0] = isBluetooth ? 0x31 : 0x02

        let leftModeIndex = isBluetooth ? 24 : 22
        let rightModeIndex = isBluetooth ? 13 : 11
        let leftSettings = settingsBySide["l2"] ?? AdaptiveTriggerSettings()
        let rightSettings = settingsBySide["r2"] ?? AdaptiveTriggerSettings()
        report[leftModeIndex] = effectMode(leftSettings.mode)
        write(effectParameters(leftSettings), into: &report, at: leftModeIndex + 1)
        report[rightModeIndex] = effectMode(rightSettings.mode)
        write(effectParameters(rightSettings), into: &report, at: rightModeIndex + 1)
        // Validate both trigger fields so a background OSC command can turn
        // either side Off without leaving its previous HID effect latched.
        report[isBluetooth ? 3 : 1] = 0x0C

        guard isBluetooth else { return report }
        report[1] = (bluetoothSequence & 0x0F) << 4
        bluetoothSequence = (bluetoothSequence &+ 1) & 0x0F
        report[2] = 0x10
        let crc = bluetoothCRC(report: report)
        report[74] = UInt8(truncatingIfNeeded: crc)
        report[75] = UInt8(truncatingIfNeeded: crc >> 8)
        report[76] = UInt8(truncatingIfNeeded: crc >> 16)
        report[77] = UInt8(truncatingIfNeeded: crc >> 24)
        return report
    }

    private func write(_ bytes: [UInt8], into report: inout [UInt8], at offset: Int) {
        for (index, byte) in bytes.enumerated() where offset + index < report.count {
            report[offset + index] = byte
        }
    }

    private func effectMode(_ mode: Int) -> UInt8 {
        switch mode {
        case 1: 0x21 // Feedback
        case 2: 0x25 // Weapon
        case 3: 0x26 // Vibration
        case 4: 0x22 // Bow
        case 5: 0x23 // Galloping
        case 6: 0x27 // Machine
        default: 0x05 // Off
        }
    }

    private func effectParameters(_ settings: AdaptiveTriggerSettings) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        guard settings.mode != 0 else { return bytes }

        let configuredStart = Int((settings.start * 9).rounded())
        let configuredEnd = Int((settings.end * 9).rounded())
        let strength = UInt8(min(max(Int((settings.strength * 8).rounded()), 1), 8))

        switch settings.mode {
        case 1: // Feedback: bit-packed resistance for trigger zones.
            let startZone = min(max(configuredStart, 0), 9)
            var zones: UInt16 = 0
            var packed: UInt32 = 0
            for zone in startZone..<10 {
                zones |= UInt16(1 << zone)
                packed |= UInt32(strength - 1) << UInt32(zone * 3)
            }
            bytes[0] = UInt8(truncatingIfNeeded: zones)
            bytes[1] = UInt8(truncatingIfNeeded: zones >> 8)
            for i in 0..<4 { bytes[2 + i] = UInt8(truncatingIfNeeded: packed >> UInt32(i * 8)) }
        case 2: // Weapon effect accepts start 2...7 and end start+1...8.
            let startZone = min(max(configuredStart, 2), 7)
            let endZone = min(max(configuredEnd, startZone + 1), 8)
            let mask = UInt16((1 << startZone) | (1 << endZone))
            bytes[0] = UInt8(truncatingIfNeeded: mask)
            bytes[1] = UInt8(truncatingIfNeeded: mask >> 8)
            bytes[2] = strength - 1
        case 3: // Vibration uses an 8-step amplitude and a 0...255 Hz value.
            bytes[0] = UInt8(min(max(configuredStart, 0), 9))
            bytes[1] = strength
            bytes[2] = UInt8(min(max(Int((settings.frequency * 255).rounded()), 0), 255))
        case 4: // Bow packs resistance and snap force into the same byte.
            let startZone = min(max(configuredStart, 1), 7)
            let endZone = min(max(configuredEnd, startZone + 1), 8)
            let mask = UInt16((1 << startZone) | (1 << endZone))
            bytes[0] = UInt8(truncatingIfNeeded: mask)
            bytes[1] = UInt8(truncatingIfNeeded: mask >> 8)
            let snap = UInt8(min(max(Int((settings.strength2 * 8).rounded()), 1), 8))
            bytes[2] = (strength - 1) | ((snap - 1) << 3)
        case 5: // Galloping alternates two force levels at the selected frequency.
            let startZone = min(max(configuredStart, 0), 8)
            let endZone = min(max(configuredEnd, startZone + 1), 9)
            let mask = UInt16((1 << startZone) | (1 << endZone))
            bytes[0] = UInt8(truncatingIfNeeded: mask)
            bytes[1] = UInt8(truncatingIfNeeded: mask >> 8)
            let first = UInt8(min(max(Int((settings.strength * 7).rounded()), 0), 7))
            let second = UInt8(min(max(Int((settings.strength2 * 7).rounded()), 0), 7))
            bytes[2] = second | (first << 3)
            bytes[3] = UInt8(min(max(Int((settings.frequency * 255).rounded()), 1), 255))
        case 6: // Machine uses alternating force levels, frequency, and period.
            let startZone = min(max(configuredStart, 1), 8)
            let endZone = min(max(configuredEnd, startZone + 1), 9)
            let mask = UInt16((1 << startZone) | (1 << endZone))
            bytes[0] = UInt8(truncatingIfNeeded: mask)
            bytes[1] = UInt8(truncatingIfNeeded: mask >> 8)
            let first = UInt8(min(max(Int((settings.strength * 7).rounded()), 0), 7))
            let second = UInt8(min(max(Int((settings.strength2 * 7).rounded()), 0), 7))
            bytes[2] = first | (second << 3)
            bytes[3] = UInt8(min(max(Int((settings.frequency * 255).rounded()), 1), 255))
            bytes[4] = UInt8(min(max(Int((settings.period * 255).rounded()), 0), 255))
        default: break
        }
        return bytes
    }

    private func bluetoothCRC(report: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func update(_ byte: UInt8, crc: inout UInt32) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        update(0xA2, crc: &crc)
        for byte in report[0..<74] { update(byte, crc: &crc) }
        return ~crc
    }
}
