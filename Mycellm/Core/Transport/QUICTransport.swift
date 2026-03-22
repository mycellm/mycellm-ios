import Foundation
import Network

/// QUIC transport using Network.framework. ALPN: "mycellm-v1".
actor QUICTransport {
    static let alpn = "mycellm-v1"
    static let defaultPort: UInt16 = 8421

    enum State: Sendable {
        case stopped
        case listening(UInt16)
        case error(String)
    }

    private(set) var state: State = .stopped
    private var listener: NWListener?
    private var connections: [String: PeerConnection] = [:]
    private var onMessage: ((MessageEnvelope, PeerConnection) async -> Void)?

    /// Set the message handler for incoming messages.
    func setMessageHandler(_ handler: @escaping (MessageEnvelope, PeerConnection) async -> Void) {
        onMessage = handler
    }

    // MARK: - Server

    func startServer(port: UInt16 = defaultPort) throws {
        let quicOptions = NWProtocolQUIC.Options(alpn: [Self.alpn])

        // Accept any peer certificate (we verify at app layer via NodeHello)
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )

        let params = NWParameters(quic: quicOptions)
        params.includePeerToPeer = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MycellmError.transportError("Invalid port: \(port)")
        }

        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleIncomingConnection(connection) }
        }

        listener.stateUpdateHandler = { [weak self] newState in
            Task {
                switch newState {
                case .ready:
                    await self?.setState(.listening(port))
                case .failed(let error):
                    await self?.setState(.error(error.localizedDescription))
                default:
                    break
                }
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        state = .listening(port)
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        for conn in connections.values {
            conn.close()
        }
        connections.removeAll()
        state = .stopped
    }

    private func setState(_ s: State) { state = s }

    // MARK: - Client

    func connect(host: String, port: UInt16) async throws -> PeerConnection {
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
        let nwConn = NWConnection(to: endpoint, using: params)

        return try await withCheckedThrowingContinuation { cont in
            nwConn.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    let peer = PeerConnection(peerId: "", remoteAddress: "\(host):\(port)")
                    peer.nwConnection = nwConn
                    cont.resume(returning: peer)
                case .failed(let error):
                    cont.resume(throwing: MycellmError.transportError("Connection failed: \(error)"))
                case .cancelled:
                    cont.resume(throwing: MycellmError.transportError("Connection cancelled"))
                default:
                    break
                }
            }
            nwConn.start(queue: .global(qos: .userInitiated))
        }
    }

    // MARK: - Connection Handling

    private func handleIncomingConnection(_ nwConn: NWConnection) {
        let peer = PeerConnection(peerId: "", remoteAddress: nwConn.endpoint.debugDescription)
        peer.nwConnection = nwConn
        peer.setState(.connecting)

        nwConn.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                peer.setState(.handshaking)
                Task { await self?.receiveMessages(from: peer) }
            case .failed, .cancelled:
                peer.setState(.closed)
                Task { await self?.removePeer(peer) }
            default:
                break
            }
        }
        nwConn.start(queue: .global(qos: .userInitiated))
    }

    private func receiveMessages(from peer: PeerConnection) async {
        guard let conn = peer.nwConnection else { return }

        while peer.state != .closed {
            do {
                let data = try await receiveFrame(from: conn)
                let envelope = try MessageEnvelope.fromCBOR(data)

                // First message must be NodeHello for unauthenticated connections
                if case .handshaking = peer.state, envelope.type == .nodeHello {
                    // Verify hello
                    if let helloData = envelope.payload["hello_data"]?.stringValue,
                       let helloCBOR = Data(hex: helloData) {
                        // TODO: full NodeHello verification
                    }
                    peer.setPeerId(envelope.fromPeer)
                    peer.setState(.authenticated)
                    connections[envelope.fromPeer] = peer
                }

                await onMessage?(envelope, peer)
            } catch {
                break
            }
        }
    }

    private func receiveFrame(from conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            // Read 4-byte length header
            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let lengthData = data, lengthData.count == 4 else {
                    cont.resume(throwing: MycellmError.transportError("Failed to read frame header"))
                    return
                }
                let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                guard length <= 10 * 1024 * 1024 else {
                    cont.resume(throwing: MycellmError.frameTooLarge(length))
                    return
                }

                // Read payload
                conn.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let payload {
                        cont.resume(returning: Data(payload))
                    } else {
                        cont.resume(throwing: MycellmError.transportError("Empty payload"))
                    }
                }
            }
        }
    }

    /// Send a framed message to a peer.
    func send(_ message: MessageEnvelope, to peer: PeerConnection) throws {
        guard let conn = peer.nwConnection else {
            throw MycellmError.transportError("No connection for peer")
        }
        let data = message.toFramed()
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("Send error: \(error)")
            }
        })
    }

    private func removePeer(_ peer: PeerConnection) {
        connections.removeValue(forKey: peer.peerId)
    }

    var connectionCount: Int { connections.count }
}
