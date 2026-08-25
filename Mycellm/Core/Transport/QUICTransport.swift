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

        // ⚠️ THIS HANDLER USED TO ONLY RESOLVE THE INITIAL CONNECT. Once
        // `connect` returned, a group that later failed or was cancelled left
        // `connected == true` forever: nothing flipped the flag and nothing told
        // BootstrapClient to reconnect. Every subsequent send then died with
        // "Failed to create stream from group" while the UI still showed
        // Connected — the exact state the iPad was in after the bootstrap
        // restarted, and the reason network chat worked once and then never
        // again until the app was killed by hand.
        grp.stateUpdateHandler = { [weak self] state in
            Log.quic.info("Group state: \(String(describing: state))")
            switch state {
            case .ready:
                resolver.resumeIfNeeded(returning: ())
            case .failed(let error):
                Log.quic.info("Group failed: \(error.localizedDescription)")
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("QUIC: \(error)"))
                Task { await self?.markDisconnected("QUIC group failed: \(error.localizedDescription)") }
            case .cancelled:
                resolver.resumeIfNeeded(throwing: MycellmError.transportError("QUIC cancelled"))
                Task { await self?.markDisconnected("QUIC group cancelled") }
            case .waiting(let error):
                // Waiting means the path went away — treat a prolonged wait as
                // a drop rather than sitting on a connection that cannot send.
                Log.quic.info("Group waiting: \(error.localizedDescription)")
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

    /// Callback invoked once when the transport goes from up to down, so the
    /// owner can reconnect. Set by BootstrapClient.
    private var onDisconnect: (@Sendable (String) -> Void)?

    func setDisconnectHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onDisconnect = handler
    }

    /// Transition to down exactly once, failing everything in flight.
    ///
    /// Pending streams are failed rather than left to their own idle timeouts:
    /// a caller waiting 20s for a connection that is already gone is 20s of a
    /// spinner it did not need to show.
    func markDisconnected(_ reason: String) {
        guard connected else { return }
        connected = false
        streams.failAll(MycellmError.transportError(reason))
        onDisconnect?(reason)
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
            // A group that cannot produce a stream is dead, whatever its state
            // handler last said. Say so once here rather than failing every
            // future send the same way with nobody reconnecting.
            markDisconnected("stream creation failed")
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

    /// Read a stream, dispatching every message it carries as it arrives.
    ///
    /// ⚠️ THIS USED TO WAIT FOR THE STREAM TO CLOSE AND THEN PARSE EXACTLY ONE
    /// CBOR MESSAGE, which forced the peer into one-stream-per-message. For a
    /// token stream that meant a 40-frame reply became 40 separate streams:
    /// QUIC orders only WITHIN a stream so they raced, and NWMultiplexGroup
    /// delivered 7 of the 40. The user saw a truncated, scrambled answer and
    /// then a timeout waiting for frames that had already been sent.
    ///
    /// A streamed reply now arrives as ONE stream of length-prefixed frames.
    /// Each is dispatched the moment it is complete — waiting for the stream to
    /// end would defeat the point of streaming — and a stream carrying a single
    /// unframed message still works, so nothing older breaks.
    private func readStream(_ stream: NWConnection) async {
        var buffer = Data()
        var dispatchedAny = false

        while true {
            let result: (Data?, Bool) = await withCheckedContinuation { cont in
                stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    cont.resume(returning: (data, isComplete))
                }
            }
            if let data = result.0 { buffer.append(data) }

            // Drain every complete frame currently buffered.
            while let (msg, rest) = Self.readFrame(buffer) {
                buffer = rest
                dispatchedAny = true
                await dispatch(msg)
            }

            if result.1 || buffer.count > 10 * 1024 * 1024 { break }
        }

        // Legacy shape: a whole stream holding one unframed CBOR message.
        if !dispatchedAny, !buffer.isEmpty,
           let msg = try? MessageEnvelope.fromCBOR(buffer) {
            await dispatch(msg)
        }
    }

    private func dispatch(_ msg: MessageEnvelope) async {
        Log.quic.info(" Parsed: \(msg.type.rawValue) id=\(msg.id)")
        if let handler = onMessage, let response = await handler(msg) {
            // Reply on a fresh client-initiated stream. The bootstrap relay's
            // send_and_wait matches the response by message id on ANY stream
            // (it sends the request on a unidirectional stream we can't write
            // back on), so a new stream — same path NodeHello uses — is correct.
            try? await send(response)
        }
    }

    /// One length-prefixed frame, and whatever is left. `nil` when the buffer
    /// does not yet hold a complete frame.
    ///
    /// The 4-byte big-endian prefix matches `MessageEnvelope.to_framed()` on
    /// the Python side. A prefix claiming more than the 10 MB ceiling is
    /// treated as "not a frame" so a corrupt or unframed stream falls through
    /// to the legacy single-message path rather than hanging forever.
    static func readFrame(_ buffer: Data) -> (MessageEnvelope, Data)? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 10 * 1024 * 1024 else { return nil }
        guard buffer.count >= 4 + length else { return nil }
        let payload = buffer.subdata(in: 4..<(4 + length))
        guard let msg = try? MessageEnvelope.fromCBOR(payload) else { return nil }
        return (msg, buffer.subdata(in: (4 + length)..<buffer.count))
    }

    // MARK: - Streaming Request

    /// Pending stream continuations keyed by request ID.
    /// Request-id → stream correlation. See `StreamRegistry` for why this is a
    /// separate, network-free type.
    private let streams = StreamRegistry()

    /// Send a streaming inference request and yield response chunks as they arrive.
    /// The returned stream emits INFERENCE_STREAM messages until INFERENCE_DONE.
    ///
    /// ⚠️ REGISTRATION HAPPENS BEFORE THE SEND, AND BEFORE THIS RETURNS. It used
    /// to happen inside a detached `Task`, so frames from a fast peer could
    /// arrive at a registry that had not been told about the request yet — they
    /// were dropped silently and the caller waited out the idle timeout. The
    /// send must come after registration, never the other way round.
    func requestStream(_ message: MessageEnvelope) -> AsyncThrowingStream<MessageEnvelope, Error> {
        let requestId = message.id
        let stream = streams.register(requestId)
        Task {
            do {
                try await self.send(message)
            } catch {
                await self.failStream(requestId, error)
            }
        }
        return stream
    }

    /// Route an incoming streaming message to the correct continuation.
    func handleStreamMessage(_ envelope: MessageEnvelope) -> Bool {
        streams.deliver(envelope)
    }

    private func failStream(_ requestId: String, _ error: Error) {
        streams.fail(requestId, error)
    }

    func cancelStream(_ requestId: String) {
        streams.cancel(requestId)
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
