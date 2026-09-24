import Foundation
import Network

struct OSCMessage {
    let address: String
    let value: Float
}

/// Sends ordered OSC bundles over UDP. UDP readiness does not confirm receipt.
final class SimpleOSCClient {
    private let queue = DispatchQueue(label: "tw.luojie.dualsense-osc.network")
    private var connection: NWConnection?
    private var currentHost: String?
    private var currentPort: UInt16?
    private var lastReportedSendError: String?
    var onStatusChange: ((String) -> Void)?

    func configure(host: String, port: UInt16?) {
        queue.async { [weak self] in
            guard let self else { return }
            let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port, port > 0, !cleanHost.isEmpty else {
                self.connection?.stateUpdateHandler = nil
                self.connection?.cancel()
                self.connection = nil
                self.currentHost = nil
                self.currentPort = nil
                self.report("請輸入有效的目標 IP 與 Port")
                return
            }
            guard self.currentHost != cleanHost || self.currentPort != port || self.connection == nil else { return }
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.currentHost = cleanHost
            self.currentPort = port
            self.openConnection()
        }
    }

    func send(_ messages: [OSCMessage]) {
        guard !messages.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.connection == nil { self.openConnection() }
            guard let connection = self.connection else { return }
            for packet in Self.encodeBundles(messages, maximumPacketSize: 1_200) {
                connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                    if let error { self?.reportSendError(error) }
                })
            }
        }
    }

    private func openConnection() {
        guard let host = currentHost, let port = currentPort,
              let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: endpointPort), using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lastReportedSendError = nil
                self.report("UDP 發送已就緒（不代表接收端已收到）")
            case .setup, .preparing:
                self.report("正在準備 UDP…")
            case .waiting(let error):
                self.report("UDP 等待網路：\(error.localizedDescription)")
            case .failed(let error):
                self.reportSendError(error)
                if self.connection === connection { self.connection = nil }
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
            message = "接收端拒絕 UDP：確認 TouchDesigner OSC In 已啟用，且 IP／Port 相符。"
        case .posix(let code) where code == .EHOSTUNREACH || code == .ENETUNREACH:
            message = "找不到 UDP 接收端：確認 Mac 與目標 IP 的網路連線。"
        default:
            message = "UDP 傳送錯誤：\(error.localizedDescription)"
        }
        guard lastReportedSendError != message else { return }
        lastReportedSendError = message
        report(message)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(message) }
    }

    private static func encodeBundles(_ messages: [OSCMessage], maximumPacketSize: Int) -> [Data] {
        var packets: [Data] = []
        var bundle = bundleHeader()
        for item in messages {
            let encoded = encodeMessage(address: item.address, value: item.value)
            let elementSize = 4 + encoded.count
            if bundle.count + elementSize > maximumPacketSize, bundle.count > 16 {
                packets.append(bundle)
                bundle = bundleHeader()
            }
            appendUInt32(UInt32(encoded.count), to: &bundle)
            bundle.append(encoded)
        }
        if bundle.count > 16 { packets.append(bundle) }
        return packets
    }

    private static func bundleHeader() -> Data {
        var data = Data("#bundle\0".utf8)
        appendUInt64(1, to: &data) // OSC immediate timetag
        return data
    }

    private static func encodeMessage(address: String, value: Float) -> Data {
        var data = Data()
        appendOSCString(address, to: &data)
        appendOSCString(",f", to: &data)
        appendUInt32(value.bitPattern, to: &data)
        return data
    }

    private static func appendOSCString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
