import Foundation

/// Correlates streaming response frames back to the request that asked for them.
///
/// ⚠️ EXTRACTED BECAUSE THE RACE THAT LIVED HERE COULD NOT BE TESTED IN PLACE.
/// `QUICTransport.requestStream` used to store its continuation inside a
/// detached `Task`, so registration had not necessarily happened by the time
/// the function returned. A peer that answered quickly — which a bootstrap
/// relaying an already-warm model does — delivered its first frames into a
/// registry that did not know about them yet. `handleStreamMessage` returned
/// false, the frames were dropped, and nothing surfaced: no error, no retry.
/// The UI showed a typing indicator until the idle timeout fired.
///
/// Owned by an actor, so no internal locking. Deliberately free of any
/// networking so the whole correlation contract can be driven directly by a
/// test: register, deliver, terminate, cancel — in any order.
final class StreamRegistry {
    typealias Continuation = AsyncThrowingStream<MessageEnvelope, Error>.Continuation

    private var continuations: [String: Continuation] = [:]
    /// Per-request reassembly state for out-of-order frames.
    private var nextSeq: [String: Int] = [:]
    private var held: [String: [Int: MessageEnvelope]] = [:]

    var activeCount: Int { continuations.count }

    /// Register `id` and return its stream. Registration is complete when this
    /// returns — that is the whole point.
    func register(_ id: String) -> AsyncThrowingStream<MessageEnvelope, Error> {
        // Frames delivered before the caller starts iterating must buffer, not
        // be discarded: `requestStream` hands the stream back and the caller
        // reaches its `for await` some time later.
        let (stream, continuation) = AsyncThrowingStream<MessageEnvelope, Error>
            .makeStream(bufferingPolicy: .unbounded)
        continuations[id] = continuation
        nextSeq[id] = 0
        held[id] = [:]
        return stream
    }

    /// Route one frame. Returns false when nothing is waiting for it, so the
    /// caller can say so rather than swallowing it.
    func deliver(_ envelope: MessageEnvelope) -> Bool {
        guard let continuation = continuations[envelope.id] else { return false }
        switch envelope.type {
        case .inferenceStream:
            // ⚠️ FRAMES ARRIVE OUT OF ORDER, AND THAT IS NOT A BUG IN QUIC.
            // The peer sends each frame with `send_message`, which opens a NEW
            // stream per message; QUIC guarantees ordering only WITHIN a
            // stream. Yielding in arrival order produced "End-to encryption
            // (-endE2" instead of "End-to-end encryption (E2EE)" — every token
            // present, shuffled. That reads as a broken model rather than a
            // transport fault, which is exactly why it survived so long.
            //
            // Frames carry `seq`. A peer too old to send one is reassembled in
            // arrival order, as before, so mixed-version fleets still work.
            guard let seq = envelope.payload["seq"]?.intValue else {
                continuation.yield(envelope)
                return true
            }
            let want = nextSeq[envelope.id] ?? 0
            if seq < want { return true }          // duplicate/late — already emitted
            held[envelope.id, default: [:]][seq] = envelope
            flush(envelope.id, into: continuation)
            return true
        case .inferenceDone, .inferenceResp:
            // DONE can overtake a frame it was sent after — same per-message
            // stream race. Emit everything still held, in order, before
            // finishing, or the tail of the reply is lost.
            drainHeld(envelope.id, into: continuation)
            continuation.finish()
            cleanup(envelope.id)
            return true
        case .error:
            let message = envelope.payload["error_message"]?.stringValue ?? "Peer error"
            drainHeld(envelope.id, into: continuation)
            continuation.finish(throwing: MycellmError.transportError(message))
            cleanup(envelope.id)
            return true
        default:
            return false
        }
    }

    /// Emit every contiguous frame starting at the one we are waiting for.
    private func flush(_ id: String, into continuation: Continuation) {
        var want = nextSeq[id] ?? 0
        while let next = held[id]?.removeValue(forKey: want) {
            continuation.yield(next)
            want += 1
        }
        nextSeq[id] = want
    }

    /// Emit whatever is held, in sequence order, gaps and all. Used at
    /// termination: a missing frame is not coming, and the text we do have
    /// beats discarding the tail.
    private func drainHeld(_ id: String, into continuation: Continuation) {
        guard let pending = held[id], !pending.isEmpty else { return }
        for key in pending.keys.sorted() {
            if let env = pending[key] { continuation.yield(env) }
        }
        held[id] = [:]
    }

    private func cleanup(_ id: String) {
        continuations.removeValue(forKey: id)
        nextSeq.removeValue(forKey: id)
        held.removeValue(forKey: id)
    }

    /// End a stream that failed before or during transmission.
    func fail(_ id: String, _ error: Error) {
        guard let continuation = continuations[id] else { return }
        drainHeld(id, into: continuation)
        continuation.finish(throwing: error)
        cleanup(id)
    }

    func cancel(_ id: String) {
        guard let continuation = continuations[id] else { return }
        drainHeld(id, into: continuation)
        continuation.finish()
        cleanup(id)
    }

    /// Terminate everything — the connection went away.
    func failAll(_ error: Error) {
        let all = continuations
        for (id, c) in all { drainHeld(id, into: c); c.finish(throwing: error) }
        continuations.removeAll()
        nextSeq.removeAll()
        held.removeAll()
    }
}
