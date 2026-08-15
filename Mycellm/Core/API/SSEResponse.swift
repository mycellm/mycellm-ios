import Foundation
import Hummingbird

/// Server-sent-events responses for the streaming node routes.
///
/// ⚠️ THE STREAM MUST OUTLIVE THE HANDLER BUT NOT THE CLIENT. Hummingbird
/// returns as soon as the handler does, then drains the body sequence; the
/// subscription therefore has to be owned by the sequence, not the handler.
/// `AsyncStream`'s `onTermination` (wired in ActivityTracker/LogBroadcaster)
/// unsubscribes when the client disconnects and the body task is cancelled —
/// which is the only unsubscribe signal there is. Anything that swallows
/// cancellation here leaks a subscriber per dashboard reload.
enum SSEResponse {

    /// Frame one JSON object as an SSE `data:` event.
    ///
    /// Python's `EventSourceResponse` sends the JSON payload with no `event:`
    /// name, so consumers listen for the default `message` event. Naming events
    /// here would silently deliver nothing to a client written against Python.
    ///
    /// Returns text rather than a buffer so the framing is checkable from the
    /// test target, which links the app but not NIO.
    static func frameText(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return "data: \(json)\n\n"
    }

    static func frame(_ object: [String: Any]) -> ByteBuffer? {
        frameText(object).map { ByteBuffer(string: $0) }
    }

    /// Build a streaming response from any sequence of wire-shaped dictionaries.
    ///
    /// A comment preamble is sent immediately: browsers hold an EventSource in
    /// `CONNECTING` until the first byte arrives, and on a quiet node the first
    /// real event can be minutes away — long enough for a proxy to time the
    /// connection out before it ever looked established.
    static func stream<S: AsyncSequence & Sendable>(
        _ sequence: S,
        map transform: @escaping @Sendable (S.Element) -> [String: Any]
    ) -> Response where S.Element: Sendable {
        let body = AsyncStream<ByteBuffer> { continuation in
            let task = Task {
                continuation.yield(ByteBuffer(string: ": ok\n\n"))
                do {
                    for try await element in sequence {
                        if Task.isCancelled { break }
                        if let buffer = frame(transform(element)) {
                            continuation.yield(buffer)
                        }
                    }
                } catch {
                    // Client went away, or the source ended. Either way the
                    // response is over; the subscription is released by the
                    // source's own onTermination.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
                .connection: "keep-alive",
            ],
            body: .init(asyncSequence: body)
        )
    }
}
