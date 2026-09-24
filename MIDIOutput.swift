import CoreMIDI
import Foundation
import Darwin

/// A system-visible virtual MIDI 1.0 source for DAWs and TouchDesigner.
final class MIDIOutput {
    let sourceName = "DualSenseOM MIDI"
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private(set) var isAvailable = false
    private var hasSentState = false
    private var smoothedValues: [UInt8: Float] = [:]

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
        guard MIDIClientCreateWithBlock("DualSenseOM MIDI" as CFString, &createdClient, nil) == noErr else { return }
        client = createdClient
        var createdSource = MIDIEndpointRef()
        guard MIDISourceCreateWithProtocol(client, sourceName as CFString, MIDIProtocolID(rawValue: 1)!, &createdSource) == noErr else { return }
        source = createdSource
        isAvailable = true
    }

    deinit {
        sendNeutral()
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func send(frame: [String: Float]) {
        guard isAvailable else { return }
        var words: [UInt32] = []
        for mapping in continuousMappings {
            guard let value = frame["c/\(mapping.path)"] else { continue }
            let isTouchCoordinate = mapping.path == "t1/x" || mapping.path == "t1/y" || mapping.path == "t2/x" || mapping.path == "t2/y"
            let touchPath = mapping.path.hasPrefix("t1/") ? "t1/touch" : "t2/touch"
            // A released touch point must return to MIDI zero, not the bipolar midpoint (64).
            let touchReleased = isTouchCoordinate && (frame["c/\(touchPath)"] ?? 0) < 0.5
            if touchReleased {
                smoothedValues[mapping.cc] = 0
                appendCC(0, number: mapping.cc, to: &words)
                continue
            }
            let effectiveValue = value
            let bounded = min(max(effectiveValue, mapping.minimum), mapping.maximum)
            let filtered = smoothedValues[mapping.cc].map { $0 + (bounded - $0) * 0.45 } ?? bounded
            smoothedValues[mapping.cc] = filtered
            let normalized = (filtered - mapping.minimum) / (mapping.maximum - mapping.minimum)
            let midiValue = UInt8((normalized * 127).rounded())
            appendCC(midiValue, number: mapping.cc, to: &words)
        }
        for mapping in buttonControllers {
            let isDown = (frame["c/\(mapping.path)"] ?? 0) >= 0.5
            let value: UInt8 = isDown ? 127 : 0
            appendCC(value, number: mapping.cc, to: &words)
        }
        send(words: words)
    }

    /// Restart analog smoothing after enabling output or reconnecting.
    func resetStateCache() {
        smoothedValues.removeAll(keepingCapacity: true)
    }

    /// Returns all mapped CCs to neutral values when output is disabled or disconnected.
    func sendNeutral() {
        guard isAvailable, hasSentState else { return }
        var words: [UInt32] = []
        for mapping in continuousMappings {
            // Stick and motion axes use the MIDI 7-bit midpoint (64) for zero;
            // triggers and released touch coordinates use 0.
            let neutral: UInt8 = mapping.path == "t1/x" || mapping.path == "t1/y" || mapping.path == "t2/x" || mapping.path == "t2/y"
                ? 0
                : ((mapping.minimum < 0 && mapping.maximum > 0) ? 64 : 0)
            words.append(Self.word(status: 0xB0, data1: mapping.cc, data2: neutral))
        }
        for mapping in buttonControllers {
            words.append(Self.word(status: 0xB0, data1: mapping.cc, data2: 0))
        }
        send(words: words)
        hasSentState = false
        smoothedValues.removeAll()
    }

    /// TouchDesigner MIDI In CHOPs may evaluate received MIDI events per frame.
    /// Emit every mapped CC in every controller sample so unchanged controls
    /// remain present when another control moves.
    private func appendCC(_ value: UInt8, number: UInt8, to words: inout [UInt32]) {
        words.append(Self.word(status: 0xB0, data1: number, data2: value))
    }

    private func send(words: [UInt32]) {
        guard isAvailable, !words.isEmpty else { return }
        hasSentState = true
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
        _ = MIDIReceivedEventList(source, UnsafePointer(list))
    }

    private static func word(status: UInt8, data1: UInt8, data2: UInt8) -> UInt32 {
        0x2000_0000 | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }
}
