import CoreMIDI
import Foundation
import Darwin

/// Creates independent full-state and change-only MIDI sources for each controller slot.
final class MIDIOutput {
    func sourceName(slot: Int) -> String { "DualSenseOM MIDI \(slot)" }
    func learnSourceName(slot: Int) -> String { "DualSenseOM MIDI Learn \(slot)" }
    private var client = MIDIClientRef()
    private var sources: [Int: MIDIEndpointRef] = [:]
    private var learnSources: [Int: MIDIEndpointRef] = [:]
    private(set) var initializationErrors: [Int: OSStatus] = [:]
    private(set) var learnInitializationErrors: [Int: OSStatus] = [:]
    private(set) var lastSendSucceeded = false
    private(set) var sentFrames = 0
    private(set) var sentLearnUpdates = 0
    private var sentStateChannels: Set<UInt8> = []
    private var sentMotionChannels: Set<UInt8> = []
    private var smoothedValues: [Int: Float] = [:]
    private var lastLearnValues: [Int: UInt8] = [:]

    private let continuousMappings: [(path: String, cc: UInt8, minimum: Float, maximum: Float)] = [
        ("lx", 16, -1, 1), ("ly", 17, -1, 1),
        ("rx", 18, -1, 1), ("ry", 19, -1, 1),
        ("l2", 20, 0, 1), ("r2", 21, 0, 1),
        ("t1/x", 22, -1, 1), ("t1/y", 23, -1, 1),
        ("t2/x", 24, -1, 1), ("t2/y", 25, -1, 1),
        ("acc/x", 26, -1, 1), ("acc/y", 27, -1, 1), ("acc/z", 28, -1, 1),
        ("gyro/x", 29, -8, 8), ("gyro/y", 30, -8, 8), ("gyro/z", 31, -8, 8)
    ]

    private let buttonControllers: [(path: String, cc: UInt8)] = [
        ("cross", 32), ("circle", 33), ("square", 34), ("triangle", 35),
        ("l1", 36), ("r1", 37), ("options", 38), ("menu", 39),
        ("l3", 40), ("r3", 41), ("tclick", 42),
        ("du", 43), ("dd", 44), ("dl", 45), ("dr", 46),
        ("t1/touch", 47), ("t2/touch", 48)
    ]

    init() {
        var createdClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("DualSenseOM MIDI" as CFString, &createdClient, nil)
        guard clientStatus == noErr else {
            initializationErrors[1] = clientStatus
            initializationErrors[2] = clientStatus
            learnInitializationErrors[1] = clientStatus
            learnInitializationErrors[2] = clientStatus
            return
        }
        client = createdClient

        for slot in 1...2 {
            var source = MIDIEndpointRef()
            let sourceStatus = MIDISourceCreateWithProtocol(client, sourceName(slot: slot) as CFString, MIDIProtocolID(rawValue: 1)!, &source)
            if sourceStatus == noErr { sources[slot] = source }
            else { initializationErrors[slot] = sourceStatus }

            var learnSource = MIDIEndpointRef()
            let learnStatus = MIDISourceCreateWithProtocol(client, learnSourceName(slot: slot) as CFString, MIDIProtocolID(rawValue: 1)!, &learnSource)
            if learnStatus == noErr { learnSources[slot] = learnSource }
            else { learnInitializationErrors[slot] = learnStatus }
        }
    }

    deinit {
        for channel in Array(sentStateChannels) { sendNeutral(channel: channel) }
        learnSources.values.forEach { MIDIEndpointDispose($0) }
        sources.values.forEach { MIDIEndpointDispose($0) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func isAvailable(slot: Int) -> Bool { sources[slot] != nil }
    func isLearnAvailable(slot: Int) -> Bool { learnSources[slot] != nil }

    @discardableResult
    func send(frame: [String: Float], includeMotion: Bool = true, channel: UInt8) -> Bool {
        guard let source = sources[Int(channel)], (1...16).contains(channel) else {
            lastSendSucceeded = false
            return false
        }
        var words: [UInt32] = []
        var frameCCValues: [(UInt8, UInt8)] = []
        func addCC(_ value: UInt8, number: UInt8) {
            appendCC(value, number: number, channel: channel, to: &words)
            frameCCValues.append((number, value))
        }

        for mapping in continuousMappings {
            let isMotion = mapping.path.hasPrefix("acc/") || mapping.path.hasPrefix("gyro/")
            guard includeMotion || !isMotion else { continue }
            guard let value = frame["c/\(mapping.path)"] else { continue }
            let isTouchCoordinate = mapping.path == "t1/x" || mapping.path == "t1/y" || mapping.path == "t2/x" || mapping.path == "t2/y"
            let touchPath = mapping.path.hasPrefix("t1/") ? "t1/touch" : "t2/touch"
            let touchReleased = isTouchCoordinate && (frame["c/\(touchPath)"] ?? 0) < 0.5
            if touchReleased {
                smoothedValues[cacheKey(channel: channel, cc: mapping.cc)] = 0
                addCC(0, number: mapping.cc)
                continue
            }
            let bounded = min(max(value, mapping.minimum), mapping.maximum)
            let key = cacheKey(channel: channel, cc: mapping.cc)
            let filtered = smoothedValues[key].map { $0 + (bounded - $0) * 0.45 } ?? bounded
            smoothedValues[key] = filtered
            let normalized = (filtered - mapping.minimum) / (mapping.maximum - mapping.minimum)
            addCC(UInt8((normalized * 127).rounded()), number: mapping.cc)
        }

        for mapping in buttonControllers {
            let isDown = (frame["c/\(mapping.path)"] ?? 0) >= 0.5
            addCC(isDown ? 127 : 0, number: mapping.cc)
        }

        let succeeded = transmit(words: words, from: source)
        lastSendSucceeded = succeeded
        if succeeded {
            sentStateChannels.insert(channel)
            sentFrames += 1
            if includeMotion { sentMotionChannels.insert(channel) }
        }
        sendLearnChanges(frameCCValues, channel: channel)
        return succeeded
    }

    func resetStateCache(channel: UInt8) {
        smoothedValues = smoothedValues.filter { $0.key / 128 != Int(channel) }
        lastLearnValues = lastLearnValues.filter { $0.key / 128 != Int(channel) }
    }

    func resetMotionStateCache(channel: UInt8) {
        for cc in UInt8(26)...UInt8(31) {
            smoothedValues.removeValue(forKey: cacheKey(channel: channel, cc: cc))
        }
    }

    func sendMotionNeutral(channel: UInt8) {
        guard let source = sources[Int(channel)], sentStateChannels.contains(channel), sentMotionChannels.contains(channel) else { return }
        let motionMappings = continuousMappings.filter {
            $0.path.hasPrefix("acc/") || $0.path.hasPrefix("gyro/")
        }
        let values = motionMappings.map { ($0.cc, UInt8(64)) }
        let words = values.map { Self.word(channel: channel, data1: $0.0, data2: $0.1) }
        lastSendSucceeded = transmit(words: words, from: source)
        if lastSendSucceeded {
            sendLearnChanges(values, channel: channel)
            sentMotionChannels.remove(channel)
        }
        for mapping in motionMappings {
            smoothedValues.removeValue(forKey: cacheKey(channel: channel, cc: mapping.cc))
        }
    }

    func sendNeutral(channel: UInt8) {
        guard let source = sources[Int(channel)], sentStateChannels.contains(channel) else { return }
        var values: [(UInt8, UInt8)] = []
        for mapping in continuousMappings {
            let isMotion = mapping.path.hasPrefix("acc/") || mapping.path.hasPrefix("gyro/")
            if isMotion && !sentMotionChannels.contains(channel) { continue }
            let neutral: UInt8 = mapping.path == "t1/x" || mapping.path == "t1/y" || mapping.path == "t2/x" || mapping.path == "t2/y"
                ? 0
                : ((mapping.minimum < 0 && mapping.maximum > 0) ? 64 : 0)
            values.append((mapping.cc, neutral))
        }
        values.append(contentsOf: buttonControllers.map { ($0.cc, UInt8(0)) })
        let words = values.map { Self.word(channel: channel, data1: $0.0, data2: $0.1) }
        if transmit(words: words, from: source) {
            sendLearnChanges(values, channel: channel)
        }
        sentStateChannels.remove(channel)
        sentMotionChannels.remove(channel)
        resetStateCache(channel: channel)
    }

    private func sendLearnChanges(_ values: [(UInt8, UInt8)], channel: UInt8) {
        guard let learnSource = learnSources[Int(channel)] else { return }
        var words: [UInt32] = []
        var changedValues: [(UInt8, UInt8)] = []
        for (cc, value) in values {
            let key = cacheKey(channel: channel, cc: cc)
            let previous = lastLearnValues[key] ?? Self.neutralValue(for: cc)
            guard previous != value else {
                lastLearnValues[key] = previous
                continue
            }
            words.append(Self.word(channel: channel, data1: cc, data2: value))
            changedValues.append((cc, value))
        }
        guard !words.isEmpty, transmit(words: words, from: learnSource) else { return }
        for (cc, value) in changedValues {
            lastLearnValues[cacheKey(channel: channel, cc: cc)] = value
        }
        sentLearnUpdates += 1
    }

    private func transmit(words: [UInt32], from endpoint: MIDIEndpointRef) -> Bool {
        guard !words.isEmpty else { return false }
        let capacity = 4_096
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIEventList>.alignment
        )
        defer { rawList.deallocate() }
        let list = rawList.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, MIDIProtocolID(rawValue: 1)!)
        for word in words {
            var eventWord = word
            packet = MIDIEventListAdd(list, capacity, packet, mach_absolute_time(), 1, &eventWord)
        }
        return MIDIReceivedEventList(endpoint, UnsafePointer(list)) == noErr
    }

    private func appendCC(_ value: UInt8, number: UInt8, channel: UInt8, to words: inout [UInt32]) {
        words.append(Self.word(channel: channel, data1: number, data2: value))
    }

    private func cacheKey(channel: UInt8, cc: UInt8) -> Int {
        Int(channel) * 128 + Int(cc)
    }

    private static func neutralValue(for cc: UInt8) -> UInt8 {
        switch cc {
        case 16...19, 26...31: return 64
        default: return 0
        }
    }

    private static func word(channel: UInt8, data1: UInt8, data2: UInt8) -> UInt32 {
        let status = UInt8(0xB0 | ((channel - 1) & 0x0F))
        return 0x2000_0000 | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }
}
