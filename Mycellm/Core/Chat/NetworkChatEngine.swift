import Foundation

/// Sending a chat to the network, independent of any view.
///
/// ⚠️ THIS LOGIC USED TO LIVE INSIDE `ChatView.sendNetworkMessage`, WHICH IS WHY
/// STREAMING TOOK FOUR ROUNDS TO DIAGNOSE. It could only be exercised by a human
/// holding a phone and typing, so every hypothesis cost a build, an install and
/// a hand-run chat — and a wrong guess looked exactly like a right one that had
/// not shipped yet. Transport selection, stream assembly and fallback are
/// ordinary logic; they belong somewhere a test and an HTTP route can call.
///
/// The view now renders what this produces. `POST /v1/node/chat/network` drives
/// the same code, so the whole path is reachable end-to-end without a UI.
actor NetworkChatEngine {

    /// Which transport carried the reply, and whether it actually streamed.
    struct Outcome: Sendable {
        var text: String = ""
        var reasoning: String = ""
        /// "quic" | "http-sse" | "http-once"
        var routedVia: String = ""
        /// Number of separate frames received. **1 means it did not stream** —
        /// the single most useful fact about this path, and the one a human
        /// staring at a chat bubble cannot report reliably.
        var chunks: Int = 0
        var firstChunkMs: Int?
        var totalMs: Int = 0
        var error: String?
        /// Why the QUIC attempt gave up, when it did. Without this a fallback
        /// to HTTP is indistinguishable from QUIC never having been tried —
        /// which cost a whole diagnostic round.
        var quicError: String?

        var didStream: Bool { chunks > 1 }
    }

    enum Transport: String, Sendable {
        case quic
        case http
    }

    private let remote: RemoteClient
    private let bootstrap: BootstrapClient?

    init(remote: RemoteClient, bootstrap: BootstrapClient?) {
        self.remote = remote
        self.bootstrap = bootstrap
    }

    /// Run a network chat, reporting each text fragment as it arrives.
    ///
    /// `onChunk` is called for every fragment, so the view appends
    /// incrementally and a test can count them. It is deliberately not
    /// optional: a caller that ignores it still proves the streaming shape.
    func send(
        messages: [RemoteClient.ChatMessage],
        model: String,
        transport: Transport,
        showReasoning: Bool = false,
        onChunk: @Sendable @escaping (String) -> Void
    ) async -> Outcome {
        let started = Date()
        var out = Outcome()
        var firstAt: Date?

        func note(_ text: String) {
            guard !text.isEmpty else { return }
            if firstAt == nil { firstAt = Date() }
            out.chunks += 1
            out.text += text
            onChunk(text)
        }

        if transport == .quic, let bootstrap {
            out.quicError = nil
            do {
                let raw = messages.map { ["role": $0.role, "content": $0.content] }
                let stream = try await bootstrap.streamInferenceWithTimeout(
                    model: model, messages: raw)
                for try await text in stream {
                    if Task.isCancelled { break }
                    note(text)
                }
                out.routedVia = "quic"
            } catch {
                out.quicError = "\(error)"
                // Only fall back when nothing was shown. Retrying after partial
                // output would duplicate the reply on screen.
                if out.chunks == 0 {
                    await httpSend(messages: messages, model: model,
                                   showReasoning: showReasoning, out: &out, note: note)
                } else {
                    out.error = "\(error)"
                    out.routedVia = "quic"
                }
            }
        } else {
            if transport == .quic { out.quicError = "no bootstrap client" }
            await httpSend(messages: messages, model: model,
                           showReasoning: showReasoning, out: &out, note: note)
        }

        if let firstAt { out.firstChunkMs = Int(firstAt.timeIntervalSince(started) * 1000) }
        out.totalMs = Int(Date().timeIntervalSince(started) * 1000)
        return out
    }

    /// SSE first; one non-streaming request only if the stream produced nothing.
    private func httpSend(
        messages: [RemoteClient.ChatMessage],
        model: String,
        showReasoning: Bool,
        out: inout Outcome,
        note: (String) -> Void
    ) async {
        do {
            let stream = await remote.stream(
                model: model, messages: messages, showReasoning: showReasoning)
            for try await chunk in stream {
                if Task.isCancelled { break }
                note(chunk.content)
                out.reasoning += chunk.reasoning
            }
            if out.chunks > 0 {
                out.routedVia = "http-sse"
                return
            }
        } catch {
            if out.chunks > 0 {
                out.error = "\(error)"
                out.routedVia = "http-sse"
                return
            }
        }

        // Nothing streamed — a server ignoring `stream: true` looks exactly
        // like a clean empty stream, so try once the ordinary way.
        do {
            let result = try await remote.completeWithMetadata(
                model: model, messages: messages, showReasoning: showReasoning)
            out.text = result.content
            out.reasoning = result.reasoningContent ?? ""
            out.chunks = result.content.isEmpty ? 0 : 1
            out.routedVia = "http-once"
        } catch {
            out.error = "\(error)"
            out.routedVia = out.routedVia.isEmpty ? "http-once" : out.routedVia
        }
    }
}
