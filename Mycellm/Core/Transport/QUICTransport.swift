import Foundation
import Network

/// QUIC transport using NWConnectionGroup for multiplexed bidirectional streams.
/// Wire format: one raw CBOR message per stream, stream closed after write.
actor QUICTransport {
    static let alpn = "mycellm-v1"
    static let defaultPort: UInt16 = 8421

    private var group: NWConnectionGroup?
    private(set) var connected = false
    private var onMessage: ((MessageEnvelope) async -> MessageEnvelope?)?
    private var pendingResponses: [String: CheckedContinuation<MessageEnvelope, Error>] = [:]

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

        let descriptor = NWMultiplexGroup(to: .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        ))
        let params = NWParameters(quic: quicOptions)
        let grp = NWConnectionGroup(with: descriptor, using: params)
        group = grp

        // Handle server-initiated streams
        grp.newConnectionHandler = { [weak self] stream in
            Task { await self?.handleIncomingStream(stream) }
        }

        let resolver = ContinuationResolver<Void>()

        grp.stateUpdateHandler = { state in
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
        grp.start(queue: .global(qos: .userInitiated))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            resolver.setContinuation(cont)
        }

        connected = true
    }

    func disconnect() {
        group?.cancel()
        group = nil
        connected = false
        // Cancel all pending responses
        for (_, cont) in pendingResponses {
            cont.resume(throwing: MycellmError.transportError("Disconnected"))
        }
        pendingResponses.removeAll()
    }

    // MARK: - Send

    /// Send a message on a new outbound stream (raw CBOR, end stream).
    func send(_ message: MessageEnvelope) async throws {
        guard let group else { throw MycellmError.transportError("Not connected") }
        guard let stream = NWConnection(from: group) else {
            throw MycellmError.transportError("Failed to create stream")
        }
        let data = message.toCBOR()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resolver = ContinuationResolver<Void>()
            resolver.setContinuation(cont)

            stream.stateUpdateHandler = { state in
                if case .ready = state {
                    stream.send(content: data, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { error in
                        if let error {
                            resolver.resumeIfNeeded(throwing: error)
                        } else {
                            resolver.resumeIfNeeded(returning: ())
                        }
                    })
                } else if case .failed(let error) = state {
                    resolver.resumeIfNeeded(throwing: error)
                }
            }
            stream.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Send and wait for response matched by message ID.
    func sendAndWait(_ message: MessageEnvelope, timeout: TimeInterval = 30) async throws -> MessageEnvelope {
        try await withThrowingTaskGroup(of: MessageEnvelope.self) { taskGroup in
            taskGroup.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerPending(id: message.id, cont: cont) }
                }
            }
            taskGroup.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MycellmError.transportError("Timeout")
            }

            // Send after registering
            try await send(message)

            let result = try await taskGroup.next()!
            taskGroup.cancelAll()
            return result
        }
    }

    private func registerPending(id: String, cont: CheckedContinuation<MessageEnvelope, Error>) {
        pendingResponses[id] = cont
    }

    // MARK: - Receive

    private func handleIncomingStream(_ stream: NWConnection) {
        stream.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { await self?.readStream(stream) }
            }
        }
        stream.start(queue: .global(qos: .userInitiated))
    }

    private nonisolated func readStreamData(_ stream: NWConnection) async -> Data {
        var buffer = Data()
        while true {
            let result: (Data?, Bool) = await withCheckedContinuation { cont in
                stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    cont.resume(returning: (data, isComplete))
                }
            }
            if let data = result.0 { buffer.append(data) }
            if result.1 || buffer.count > 10 * 1024 * 1024 { break }
        }
        return buffer
    }

    private func readStream(_ stream: NWConnection) async {
        let buffer = await readStreamData(stream)
        guard !buffer.isEmpty else { return }

        guard let envelope = try? MessageEnvelope.fromCBOR(buffer) else { return }

        // Check pending responses first
        if let cont = pendingResponses.removeValue(forKey: envelope.id) {
            cont.resume(returning: envelope)
            return
        }

        // Dispatch to handler
        if let handler = onMessage, let response = await handler(envelope) {
            try? await send(response)
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
