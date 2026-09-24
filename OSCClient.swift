import Foundation
import Network

struct OSCMessage {
    let address: String
    let value: Float
}

/// Sends each ordered value frame as an OSC bundle over UDP.
final class SimpleOSCClient {
    private let queue = DispatchQueue(label: "tw.luojie.dualsense-osc.network")
    private var connection: NWConnection?
    private var currentHost: String?
    private var currentPort: UInt16?
    private var lastError: String?
    private var retryAfter = Date.distantPast
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
            self.retryAfter = .distantPast
            self.openConnection()
        }
    }

    func send(_ messages: [OSCMessage]) {
        guard !messages.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.connection == nil {
                guard Date() >= self.retryAfter else { return }
                self.openConnection()
            }
            guard let connection = self.connection else { return }
            let packets = Self.encodeBundles(messages, maximumPacketSize: 1_200)
            for packet in packets {
                connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
                    guard let error else { return }
                    self?.queue.async {
                        guard let self else { return }
                        self.handleSendError(error, connection: connection)
                    }
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
                self.lastError = nil
                self.report("UDP 發送已就緒（不代表接收端已收到）")
            case .setup, .preparing:
                self.report("正在準備 UDP…")
            case .waiting(let error):
                self.report("UDP 等待網路：\(error.localizedDescription)")
            case .failed(let error):
                self.handleSendError(error, connection: connection)
            case .cancelled:
                break
            @unknown default:
                self.report("UDP 狀態未知")
            }
        }
        connection.start(queue: queue)
    }

    private func handleSendError(_ error: NWError, connection: NWConnection?) {
        reportSendError(error)
        if self.connection === connection {
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
        }
        // ECONNREFUSED is common when no OSC receiver is listening. Avoid retrying
        // on every 60 Hz control frame; the next send will retry after this backoff.
        if case .posix(let code) = error, code == .ECONNREFUSED {
            retryAfter = Date().addingTimeInterval(2)
        } else {
            retryAfter = Date().addingTimeInterval(0.5)
        }
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
        guard lastError != message else { return }
        lastError = message
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
            if bundle.count + 4 + encoded.count > maximumPacketSize, bundle.count > 16 {
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
        appendUInt64(1, to: &data)
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
