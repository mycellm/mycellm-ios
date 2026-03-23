import Foundation
import Network

/// Minimal STUN Binding Request/Response client.
/// Sends one UDP packet, parses XOR-MAPPED-ADDRESS from response.
enum STUNClient {
    static let magicCookie: UInt32 = 0x2112A442
    static let bindingRequest: UInt16 = 0x0001
    static let bindingResponse: UInt16 = 0x0101
    static let attrXorMappedAddress: UInt16 = 0x0020
    static let attrMappedAddress: UInt16 = 0x0001

    struct MappedAddress: Sendable {
        let ip: String
        let port: Int
    }

    /// Send a STUN Binding Request and return the mapped address.
    static func query(host: String, port: UInt16, timeout: TimeInterval = 3.0) async throws -> MappedAddress {
        let txnID = Data.random(count: 12)
        let request = buildBindingRequest(txnID: txnID)

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )

        let resolver = STUNResolver()

        return try await withCheckedThrowingContinuation { cont in
            resolver.setContinuation(cont)

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                conn.cancel()
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("STUN timeout"))
            }

            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: request, completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 20, maximumLength: 548) { data, _, _, error in
                        timeoutTask.cancel()
                        if let error {
                            conn.cancel()
                            resolver.resumeIfNeeded(throwing: error)
                            return
                        }
                        guard let data, data.count >= 20 else {
                            conn.cancel()
                            resolver.resumeIfNeeded(throwing: MycellmError.transportError("STUN: short response"))
                            return
                        }
                        if let mapped = parseBindingResponse(data: data, txnID: txnID) {
                            conn.cancel()
                            resolver.resumeIfNeeded(returning: mapped)
                        } else {
                            conn.cancel()
                            resolver.resumeIfNeeded(throwing: MycellmError.transportError("STUN: no mapped address"))
                        }
                    }
                } else if case .failed(let error) = state {
                    timeoutTask.cancel()
                    resolver.resumeIfNeeded(throwing: error)
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    // MARK: - Build/Parse

    private static func buildBindingRequest(txnID: Data) -> Data {
        var data = Data(capacity: 20)
        // Type: Binding Request
        data.append(contentsOf: withUnsafeBytes(of: bindingRequest.bigEndian) { Array($0) })
        // Length: 0
        data.append(contentsOf: [0, 0])
        // Magic Cookie
        data.append(contentsOf: withUnsafeBytes(of: magicCookie.bigEndian) { Array($0) })
        // Transaction ID
        data.append(txnID)
        return data
    }

    private static func parseBindingResponse(data: Data, txnID: Data) -> MappedAddress? {
        guard data.count >= 20 else { return nil }

        let msgType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard msgType == bindingResponse else { return nil }

        let magic = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        guard magic == magicCookie else { return nil }

        let respTxn = data[8..<20]
        guard respTxn == txnID else { return nil }

        // Parse attributes
        var offset = 20
        while offset + 4 <= data.count {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLen = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4
            guard offset + attrLen <= data.count else { break }

            if attrType == attrXorMappedAddress, attrLen >= 8 {
                return parseXorMapped(data: data, offset: offset)
            } else if attrType == attrMappedAddress, attrLen >= 8 {
                return parseMapped(data: data, offset: offset)
            }

            offset += attrLen + (4 - attrLen % 4) % 4  // pad to 4-byte
        }
        return nil
    }

    private static func parseXorMapped(data: Data, offset: Int) -> MappedAddress? {
        let family = data[offset + 1]
        guard family == 0x01 else { return nil } // IPv4

        let xport = (UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])) ^ UInt16(magicCookie >> 16)
        let xip = (UInt32(data[offset + 4]) << 24 | UInt32(data[offset + 5]) << 16 |
                   UInt32(data[offset + 6]) << 8 | UInt32(data[offset + 7])) ^ magicCookie

        let ip = "\(xip >> 24).\((xip >> 16) & 0xFF).\((xip >> 8) & 0xFF).\(xip & 0xFF)"
        return MappedAddress(ip: ip, port: Int(xport))
    }

    private static func parseMapped(data: Data, offset: Int) -> MappedAddress? {
        let family = data[offset + 1]
        guard family == 0x01 else { return nil }

        let port = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
        let ip = "\(data[offset + 4]).\(data[offset + 5]).\(data[offset + 6]).\(data[offset + 7])"
        return MappedAddress(ip: ip, port: port)
    }
}

/// Thread-safe one-shot resolver for STUN continuations.
private final class STUNResolver: @unchecked Sendable {
    private var continuation: CheckedContinuation<STUNClient.MappedAddress, Error>?
    private var resolved = false
    private let lock = NSLock()

    func setContinuation(_ cont: CheckedContinuation<STUNClient.MappedAddress, Error>) {
        lock.withLock { continuation = cont }
    }

    func resumeIfNeeded(returning value: STUNClient.MappedAddress) {
        lock.withLock {
            guard !resolved else { return }
            resolved = true
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resumeIfNeeded(throwing error: Error) {
        lock.withLock {
            guard !resolved else { return }
            resolved = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
