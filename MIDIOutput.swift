import CoreMIDI
import Foundation
import Darwin

/// A full-state MIDI source for TouchDesigner plus a change-only source for MIDI Learn.
final class MIDIOutput {
    let sourceName = "DualSenseOM MIDI"
    let learnSourceName = "DualSenseOM MIDI Learn"
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var learnSource = MIDIEndpointRef()
    private(set) var isAvailable = false
    private(set) var initializationError: OSStatus?
    private(set) var isLearnAvailable = false
    private(set) var learnInitializationError: OSStatus?
    private(set) var lastSendSucceeded = false
    private(set) var sentFrames = 0
    private(set) var sentLearnUpdates = 0
    private var hasSentState = false
    private var hasSentMotion = false
    private var smoothedValues: [UInt8: Float] = [:]
    private var lastLearnValues: [UInt8: UInt8] = [:]

    private let continuousMappings: [(path: String, cc: UInt8, minimum: Float, maximum: Float)] = [
        ("lx", 16, -1, 1), ("ly", 17, -1, 1),
        ("rx", 18, -1, 1), ("ry", 19, -1, 1),
        ("l2", 20, 0, 1), ("r2", 21, 0, 1),
        ("t1/x", 22, -1, 1), ("t1/y", 23, -1, 1),
        ("t2/x", 24, -1, 1), ("t2/y", 25, -1, 1),
        ("acc/x", 26, -1, 1), ("acc/y", 27, -1, 1), ("acc/z", 28, -1, 1),
        ("gyro/x", 29, -8, 8), ("gyro/y", 30, -8, 8), ("gyro/z", 31, -8, 8)
    ]

    /// Button and touch states use CC only, so each control has exactly one channel.
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
            initializationError = clientStatus
            return
        }
        client = createdClient
        var createdSource = MIDIEndpointRef()
        let sourceStatus = MIDISourceCreateWithProtocol(client, sourceName as CFString, MIDIProtocolID(rawValue: 1)!, &createdSource)
        guard sourceStatus == noErr else {
            initializationError = sourceStatus
            return
        }
        source = createdSource
        isAvailable = true

        var createdLearnSource = MIDIEndpointRef()
        let learnStatus = MIDISourceCreateWithProtocol(client, learnSourceName as CFString, MIDIProtocolID(rawValue: 1)!, &createdLearnSource)
        guard learnStatus == noErr else {
            learnInitializationError = learnStatus
            return
        }
        learnSource = createdLearnSource
        isLearnAvailable = true
    }

    deinit {
        sendNeutral()
        if learnSource != 0 { MIDIEndpointDispose(learnSource) }
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    @discardableResult
    func send(frame: [String: Float], includeMotion: Bool = true) -> Bool {
        guard isAvailable else {
            lastSendSucceeded = false
            return false
        }
        var words: [UInt32] = []
        var frameCCValues: [(UInt8, UInt8)] = []
        func addCC(_ value: UInt8, number: UInt8) {
            appendCC(value, number: number, to: &words)
            frameCCValues.append((number, value))
        }
        for mapping in continuousMappings {
            let isMotion = mapping.path.hasPrefix("acc/") || mapping.path.hasPrefix("gyro/")
            guard includeMotion || !isMotion else { continue }
            guard let value = frame["c/\(mapping.path)"] else { continue }
            let isTouchCoordinate = mapping.path == "t1/x" || mapping.path == "t1/y" || mapping.path == "t2/x" || mapping.path == "t2/y"
            let touchPath = mapping.path.hasPrefix("t1/") ? "t1/touch" : "t2/touch"
            // A released touch point must return to MIDI zero, not the bipolar midpoint (64).
            let touchReleased = isTouchCoordinate && (frame["c/\(touchPath)"] ?? 0) < 0.5
            if touchReleased {
                smoothedValues[mapping.cc] = 0
                addCC(0, number: mapping.cc)
                continue
            }
            let effectiveValue = value
            let bounded = min(max(effectiveValue, mapping.minimum), mapping.maximum)
            let filtered = smoothedValues[mapping.cc].map { $0 + (bounded - $0) * 0.45 } ?? bounded
            smoothedValues[mapping.cc] = filtered
            let normalized = (filtered - mapping.minimum) / (mapping.maximum - mapping.minimum)
            let midiValue = UInt8((normalized * 127).rounded())
            addCC(midiValue, number: mapping.cc)
        }
        for mapping in buttonControllers {
            let isDown = (frame["c/\(mapping.path)"] ?? 0) >= 0.5
            let value: UInt8 = isDown ? 127 : 0
            addCC(value, number: mapping.cc)
        }
        let succeeded = send(words: words)
        lastSendSucceeded = succeeded
        if succeeded {
            sentFrames += 1
            if includeMotion { hasSentMotion = true }
            sendLearnChanges(frameCCValues)
        }
        return succeeded
    }

    /// Restart analog smoothing after enabling output or reconnecting.
    func resetStateCache() {
        smoothedValues.removeAll(keepingCapacity: true)
    }

    func resetMotionStateCache() {
        for cc in UInt8(26)...UInt8(31) {
            smoothedValues.removeValue(forKey: cc)
        }
    }

    /// Centers motion CCs when motion output is switched off, so receivers
    /// don't retain the last tilt/rotation value.
    func sendMotionNeutral() {
        guard isAvailable, hasSentState, hasSentMotion else { return }
        let motionMappings = continuousMappings.filter {
            $0.path.hasPrefix("acc/") || $0.path.hasPrefix("gyro/")
        }
        let words = motionMappings.map {
            Self.word(status: 0xB0, data1: $0.cc, data2: 64)
        }
        lastSendSucceeded = send(words: words)
        if lastSendSucceeded {
            hasSentMotion = false
            sendLearnChanges(motionMappings.map { ($0.cc, UInt8(64)) })
        }
        for mapping in motionMappings { smoothedValues.removeValue(forKey: mapping.cc) }
    }

    /// Returns all mapped CCs to neutral values when output is disabled or disconnected.
    func sendNeutral() {
        guard isAvailable, hasSentState else { return }
        var words: [UInt32] = []
        var neutralLearnValues: [(UInt8, UInt8)] = []
        for mapping in continuousMappings {
            let isMotion = mapping.path.hasPrefix("acc/") || mapping.path.hasPrefix("gyro/")
            if isMotion && !hasSentMotion { continue }
            // Stick and motion axes use the MIDI 7-bit midpoint (64) for zero;
            // triggers and released touch coordinates use 0.
            let neutral: UInt8 = mapping.path == "t1/x" || mapping.path == "t1/y" || mapping.path == "t2/x" || mapping.path == "t2/y"
                ? 0
                : ((mapping.minimum < 0 && mapping.maximum > 0) ? 64 : 0)
            words.append(Self.word(status: 0xB0, data1: mapping.cc, data2: neutral))
            neutralLearnValues.append((mapping.cc, neutral))
        }
        for mapping in buttonControllers {
            words.append(Self.word(status: 0xB0, data1: mapping.cc, data2: 0))
            neutralLearnValues.append((mapping.cc, 0))
        }
        let succeeded = send(words: words)
        if succeeded {
            sendLearnChanges(neutralLearnValues)
            hasSentMotion = false
        }
        hasSentState = false
        smoothedValues.removeAll()
    }

    /// TouchDesigner MIDI In CHOPs may evaluate received MIDI events per frame.
    /// Emit every mapped CC in every controller sample so unchanged controls
    /// remain present when another control moves.
    private func appendCC(_ value: UInt8, number: UInt8, to words: inout [UInt32]) {
        words.append(Self.word(status: 0xB0, data1: number, data2: value))
    }

    @discardableResult
    private func send(words: [UInt32]) -> Bool {
        guard isAvailable else { return false }
        let succeeded = transmit(words: words, from: source)
        if succeeded { hasSentState = true }
        return succeeded
    }

    private func sendLearnChanges(_ values: [(UInt8, UInt8)]) {
        guard isLearnAvailable else { return }
        var words: [UInt32] = []
        var changedValues: [(UInt8, UInt8)] = []
        for (cc, value) in values {
            let previous = lastLearnValues[cc] ?? Self.neutralValue(for: cc)
            guard previous != value else {
                lastLearnValues[cc] = previous
                continue
            }
            words.append(Self.word(status: 0xB0, data1: cc, data2: value))
            changedValues.append((cc, value))
        }
        guard !words.isEmpty, transmit(words: words, from: learnSource) else { return }
        for (cc, value) in changedValues { lastLearnValues[cc] = value }
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

    private static func neutralValue(for cc: UInt8) -> UInt8 {
        switch cc {
        case 16...19, 26...31: return 64
        default: return 0
        }
    }

    private static func word(status: UInt8, data1: UInt8, data2: UInt8) -> UInt32 {
        0x2000_0000 | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }
}
