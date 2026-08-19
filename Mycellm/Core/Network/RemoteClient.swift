import Foundation

/// OpenAI-compatible API client for remote inference.
/// Works with any endpoint: mycellm nodes, OpenRouter, ollama, etc.
actor RemoteClient {
    var endpoint: URL?
    var apiKey: String = ""

    struct ChatMessage: Codable, Sendable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        /// OpenAI-o-series style reasoning control. Omitted (nil) lets the
        /// server apply its default policy (MYCELLM_HIDE_REASONING_BY_DEFAULT).
        let reasoning: ReasoningOptions?

        struct ReasoningOptions: Codable {
            let exclude: Bool
        }
    }

    /// Streaming chunk with split content vs reasoning. Pure-content chunks
    /// have reasoning="" and vice versa. Either may be empty.
    struct StreamChunk: Sendable {
        let content: String
        let reasoning: String
        /// Which node served this, when the server says so. Defaulted so the
        /// existing call sites that only build content keep compiling.
        var servedBy: String? = nil
        var model: String? = nil
    }

    /// Non-streaming response carrying both the user-facing answer and any
    /// reasoning the server surfaced via the reasoning_content side channel.
    struct ChatResponse: Sendable {
        let content: String
        let reasoningContent: String
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let sourceNode: String
        let latencyMs: Int
    }

    func configure(endpoint: String, apiKey: String = "") {
        // If endpoint already contains a path (e.g. /v1/public), append /chat/completions
        // Otherwise append the full /v1/chat/completions
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        if base.contains("/v1/") {
            self.endpoint = URL(string: base + "/chat/completions")
        } else {
            self.endpoint = URL(string: base + "/v1/chat/completions")
        }
        self.apiKey = apiKey
    }

    var isConfigured: Bool { endpoint != nil }

    /// Stream chat completions. Yields StreamChunk values that carry either
    /// content (the user-facing answer) or reasoning (model's internal
    /// thinking) — never both. Servers that don't surface reasoning emit
    /// only content chunks, so old call sites still work.
    func stream(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        showReasoning: Bool = false
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            guard let url = endpoint else {
                continuation.finish(throwing: MycellmError.transportError("No remote endpoint configured"))
                return
            }

            let body = ChatRequest(
                model: model,
                messages: messages,
                temperature: temperature,
                max_tokens: maxTokens,
                stream: true,
                reasoning: ChatRequest.ReasoningOptions(exclude: !showReasoning)
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try? JSONEncoder().encode(body)

            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        continuation.finish(throwing: MycellmError.transportError("HTTP \(http.statusCode): \(body)"))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else {
                            continue
                        }
                        // OpenAI o-series convention: delta.reasoning_content
                        // alongside / interleaved with delta.content.
                        let content = (delta["content"] as? String) ?? ""
                        let reasoning = (delta["reasoning_content"] as? String) ?? ""
                        // The gateway stamps every SSE chunk with which node
                        // served it; passing it through means the HTTP path can
                        // attribute a reply the same way the QUIC path does.
                        let meta = json["mycellm"] as? [String: Any]
                        let node = meta?["node"] as? String
                        let servedModel = json["model"] as? String
                        if !content.isEmpty || !reasoning.isEmpty || node != nil {
                            continuation.yield(StreamChunk(
                                content: content, reasoning: reasoning,
                                servedBy: node, model: servedModel))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming completion. Convenience wrapper that drops reasoning.
    func complete(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) async throws -> String {
        try await completeWithMetadata(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens
        ).content
    }

    typealias CompletionResult = ChatResponse

    /// Non-streaming completion with full metadata. When `showReasoning` is
    /// true, the server includes a `reasoning_content` side-channel which
    /// is surfaced on the returned ChatResponse so the UI can render it
    /// separately from the user-facing answer.
    func completeWithMetadata(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        showReasoning: Bool = false
    ) async throws -> ChatResponse {
        guard let url = endpoint else {
            throw MycellmError.transportError("No remote endpoint configured")
        }

        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            max_tokens: maxTokens,
            stream: false,
            reasoning: ChatRequest.ReasoningOptions(exclude: !showReasoning)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MycellmError.transportError("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MycellmError.transportError("Invalid response format")
        }

        let usage = json["usage"] as? [String: Any]
        let mycellm = json["mycellm"] as? [String: Any]
        let reasoning = (message["reasoning_content"] as? String) ?? ""

        return ChatResponse(
            content: content,
            reasoningContent: reasoning,
            model: json["model"] as? String ?? "",
            promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage?["completion_tokens"] as? Int ?? 0,
            sourceNode: mycellm?["node"] as? String ?? "",
            latencyMs: mycellm?["latency_ms"] as? Int ?? 0
        )
    }

    /// Discovery: fetch per-model capabilities (supports_thinking etc.)
    /// so the UI can gate affordances on whether the network actually has
    /// a thinking-capable model.
    struct CapabilitiesSummary: Sendable {
        let totalModels: Int
        let thinkingCapableCount: Int
    }

    func fetchCapabilities() async throws -> CapabilitiesSummary {
        guard let base = endpoint?.deletingLastPathComponent().deletingLastPathComponent(),
              let url = URL(string: base.absoluteString + "/v1/models/capabilities") else {
            return CapabilitiesSummary(totalModels: 0, thinkingCapableCount: 0)
        }
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return CapabilitiesSummary(totalModels: 0, thinkingCapableCount: 0)
        }
        let thinking = models.filter { ($0["supports_thinking"] as? Bool) == true }.count
        return CapabilitiesSummary(totalModels: models.count, thinkingCapableCount: thinking)
    }

    /// Fetch available models from the remote endpoint.
    func listModels() async throws -> [String] {
        guard let base = endpoint?.deletingLastPathComponent().deletingLastPathComponent(),
              let url = URL(string: base.absoluteString + "/v1/models") else {
            return []
        }

        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return [] }

        return models.compactMap { $0["id"] as? String }
    }
}
