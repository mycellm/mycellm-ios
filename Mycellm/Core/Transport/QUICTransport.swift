import Foundation
import Network

/// QUIC transport using Network.framework.
/// Wire format: raw CBOR per message (no length prefix), matching Python aioquic.
actor QUICTransport {
    static let alpn = "mycellm-v1"
    static let defaultPort: UInt16 = 8421

    private var connection: NWConnection?
    private(set) var connected = false
    private var onMessage: ((MessageEnvelope) async -> MessageEnvelope?)?
    private var receiveBuffer = Data()

    func setMessageHandler(_ handler: @escaping (MessageEnvelope) async -> MessageEnvelope?) {
        onMessage = handler
    }

    // MARK: - Connect

    func connect(host: String, port: UInt16) async throws {
        let quicOptions = NWProtocolQUIC.Options(alpn: [Self.alpn])
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )

        let params = NWParameters(quic: quicOptions)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        let resolver = ContinuationResolver<Void>()

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                resolver.resumeIfNeeded(returning: ())
            case .failed(let error):
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("QUIC: \(error)"))
            case .cancelled:
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("QUIC cancelled"))
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            resolver.setContinuation(cont)
        }

        connected = true
        // Start receiving
        startReceiving()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connected = false
        receiveBuffer = Data()
    }

    // MARK: - Send

    /// Send a raw CBOR message. Uses the main QUIC connection.
    /// The message is prefixed with a 4-byte length for framing (matches transport.quic framing).
    func send(_ message: MessageEnvelope) async throws {
        guard let conn = connection else {
            throw MycellmError.transportError("Not connected")
        }

        // Use the envelope's to_cbor (with 0x00/0x01 prefix) wrapped in 4-byte length frame
        // This matches Python's MessageEnvelope.to_framed()
        let framedData = message.toFramed()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: framedData, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - Receive

    private nonisolated func startReceiving() {
        Task { await self.receiveLoop() }
    }

    private func receiveLoop() async {
        guard let conn = connection else { return }

        while connected {
            do {
                let data: Data = try await withCheckedThrowingContinuation { cont in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let error {
                            cont.resume(throwing: error)
                        } else if let data {
                            cont.resume(returning: data)
                        } else if isComplete {
                            cont.resume(throwing: MycellmError.transportError("Connection closed"))
                        } else {
                            cont.resume(returning: Data())
                        }
                    }
                }

                if data.isEmpty { continue }
                receiveBuffer.append(data)

                // Try to parse framed messages from buffer
                while true {
                    do {
                        let (msg, remaining) = try MessageEnvelope.readFrame(receiveBuffer)
                        guard let msg else { break } // incomplete frame
                        receiveBuffer = remaining

                        if let handler = onMessage {
                            Task {
                                if let response = await handler(msg) {
                                    try? await self.send(response)
                                }
                            }
                        }
                    } catch {
                        // Try parsing as raw CBOR (no length prefix)
                        if let msg = try? MessageEnvelope.fromCBOR(receiveBuffer) {
                            receiveBuffer = Data()
                            if let handler = onMessage {
                                Task {
                                    if let response = await handler(msg) {
                                        try? await self.send(response)
                                    }
                                }
                            }
                        }
                        break
                    }
                }
            } catch {
                if connected {
                    connected = false
                }
                break
            }
        }
    }

    var isConnected: Bool { connected }
}

// MARK: - Thread-safe continuation resolver

private final class ContinuationResolver<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved = false
    private let lock = NSLock()

    func setContinuation(_ cont: CheckedContinuation<T, Error>) {
        lock.withLock {
            if resolved { return }
            continuation = cont
        }
    }

    func resumeIfNeeded(returning value: T) {
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
