import Foundation
import Network

/// QUIC transport: NWConnectionGroup for bidirectional multiplexed streams.
/// Send: ContentContext(isFinal: true) per message (matches aioquic end_stream).
/// Receive: newConnectionHandler for server-initiated streams.
actor QUICTransport {
    static let alpn = "mycellm-v1"
    static let defaultPort: UInt16 = 8421

    private var group: NWConnectionGroup?
    private var mainConnection: NWConnection?
    private(set) var connected = false
    private var onMessage: ((MessageEnvelope) async -> MessageEnvelope?)?

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
        quicOptions.idleTimeout = 120_000

        let descriptor = NWMultiplexGroup(to: .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        ))
        let params = NWParameters(quic: quicOptions)
        let grp = NWConnectionGroup(with: descriptor, using: params)
        group = grp

        // Handle server-initiated streams (pings, inference requests)
        grp.newConnectionHandler = { [weak self] incomingStream in
            Log.quic.info(" New incoming stream")
            Task { await self?.handleIncomingStream(incomingStream) }
        }

        let resolver = ContinuationResolver<Void>()

        grp.stateUpdateHandler = { state in
            Log.quic.info("Group state: \(String(describing: state))")
            switch state {
            case .ready:
                resolver.resumeIfNeeded(returning: ())
            case .failed(let error):
                Log.quic.info("Group failed: \(error.localizedDescription)")
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("QUIC: \(error)"))
            case .cancelled:
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("QUIC cancelled"))
            default:
                break
            }
        }
        grp.start(queue: .global(qos: .userInitiated))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            resolver.setContinuation(cont)
        }

        connected = true
        Log.quic.info(" Connected to \(host):\(port)")
    }

    func disconnect() {
        connected = false
        mainConnection?.cancel()
        mainConnection = nil
        group?.cancel()
        group = nil
    }

    // MARK: - Send

    /// Send a message by creating a new outbound stream from the group.
    func send(_ message: MessageEnvelope) async throws {
        guard let group else {
            throw MycellmError.transportError("Not connected")
        }

        let cborData = message.toCBOR()
        Log.quic.info(" Sending \(cborData.count) bytes (type: \(message.type.rawValue))")

        // Create a new stream from the group
        guard let stream = NWConnection(from: group) else {
            throw MycellmError.transportError("Failed to create stream from group")
        }

        let resolver = ContinuationResolver<Void>()

        stream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Stream is ready — send data and close
                stream.send(content: cborData,
                            contentContext: .finalMessage,
                            isComplete: true,
                            completion: .contentProcessed { error in
                    if let error {
                        Log.quic.info("Send error: \(error.localizedDescription)")
                        resolver.resumeIfNeeded(throwing: error)
                    } else {
                        Log.quic.info(" Send OK: \(cborData.count) bytes")
                        resolver.resumeIfNeeded(returning: ())
                    }
                })
            case .failed(let error):
                Log.quic.info("Stream failed: \(error.localizedDescription)")
                resolver.resumeIfNeeded(throwing: error)
            default:
                break
            }
        }
        stream.start(queue: .global(qos: .userInitiated))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            resolver.setContinuation(cont)
        }
    }

    // MARK: - Receive (server-initiated streams)

    private func handleIncomingStream(_ stream: NWConnection) {
        stream.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { await self?.readStream(stream) }
            }
        }
        stream.start(queue: .global(qos: .userInitiated))
    }

    private func readStream(_ stream: NWConnection) async {
        var buffer = Data()

        // Read all data until stream completes
        while true {
            let result: (Data?, Bool) = await withCheckedContinuation { cont in
                stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    cont.resume(returning: (data, isComplete))
                }
            }
            if let data = result.0 { buffer.append(data) }
            if result.1 || buffer.count > 10 * 1024 * 1024 { break }
        }

        guard !buffer.isEmpty else { return }
        Log.quic.info(" Stream received \(buffer.count) bytes")

        // Parse CBOR
        guard let msg = try? MessageEnvelope.fromCBOR(buffer) else {
            Log.quic.info(" Failed to parse incoming message (\(buffer.count) bytes)")
            return
        }
        Log.quic.info(" Parsed: \(msg.type.rawValue) id=\(msg.id)")

        if let handler = onMessage, let response = await handler(msg) {
            try? await send(response)
        }
    }

    // MARK: - Streaming Request

    /// Pending stream continuations keyed by request ID.
    private var streamContinuations: [String: AsyncThrowingStream<MessageEnvelope, Error>.Continuation] = [:]

    /// Send a streaming inference request and yield response chunks as they arrive.
    /// The returned stream emits INFERENCE_STREAM messages until INFERENCE_DONE.
    func requestStream(_ message: MessageEnvelope) -> AsyncThrowingStream<MessageEnvelope, Error> {
        let requestId = message.id
        return AsyncThrowingStream { continuation in
            Task {
                self.streamContinuations[requestId] = continuation
                do {
                    try await self.send(message)
                } catch {
                    self.streamContinuations.removeValue(forKey: requestId)
                    continuation.finish(throwing: error)
                }
                continuation.onTermination = { _ in
                    Task { await self.cancelStream(requestId) }
                }
            }
        }
    }

    /// Route an incoming streaming message to the correct continuation.
    func handleStreamMessage(_ envelope: MessageEnvelope) -> Bool {
        guard let continuation = streamContinuations[envelope.id] else { return false }
        switch envelope.type {
        case .inferenceStream:
            continuation.yield(envelope)
            return true
        case .inferenceDone:
            continuation.finish()
            streamContinuations.removeValue(forKey: envelope.id)
            return true
        case .error:
            let msg = envelope.payload["error_message"]?.stringValue ?? "Peer error"
            continuation.finish(throwing: MycellmError.transportError(msg))
            streamContinuations.removeValue(forKey: envelope.id)
            return true
        default:
            return false
        }
    }

    private func cancelStream(_ requestId: String) {
        streamContinuations.removeValue(forKey: requestId)
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
