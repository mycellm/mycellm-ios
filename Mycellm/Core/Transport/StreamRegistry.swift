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
        return stream
    }

    /// Route one frame. Returns false when nothing is waiting for it, so the
    /// caller can say so rather than swallowing it.
    func deliver(_ envelope: MessageEnvelope) -> Bool {
        guard let continuation = continuations[envelope.id] else { return false }
        switch envelope.type {
        case .inferenceStream:
            continuation.yield(envelope)
            return true
        case .inferenceDone, .inferenceResp:
            continuation.finish()
            continuations.removeValue(forKey: envelope.id)
            return true
        case .error:
            let message = envelope.payload["error_message"]?.stringValue ?? "Peer error"
            continuation.finish(throwing: MycellmError.transportError(message))
            continuations.removeValue(forKey: envelope.id)
            return true
        default:
            return false
        }
    }

    /// End a stream that failed before or during transmission.
    func fail(_ id: String, _ error: Error) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.finish(throwing: error)
    }

    func cancel(_ id: String) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.finish()
    }

    /// Terminate everything — the connection went away.
    func failAll(_ error: Error) {
        let all = continuations
        continuations.removeAll()
        for (_, c) in all { c.finish(throwing: error) }
    }
}
