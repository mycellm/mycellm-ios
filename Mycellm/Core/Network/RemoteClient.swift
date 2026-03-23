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

    /// Stream chat completions. Yields delta content strings.
    func stream(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) -> AsyncThrowingStream<String, Error> {
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
                stream: true
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
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming completion.
    func complete(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) async throws -> String {
        guard let url = endpoint else {
            throw MycellmError.transportError("No remote endpoint configured")
        }

        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            max_tokens: maxTokens,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
        return content
    }

    struct CompletionResult: Sendable {
        let content: String
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let sourceNode: String
        let latencyMs: Int
    }

    /// Non-streaming completion with full metadata.
    func completeWithMetadata(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) async throws -> CompletionResult {
        guard let url = endpoint else {
            throw MycellmError.transportError("No remote endpoint configured")
        }

        let body = ChatRequest(model: model, messages: messages, temperature: temperature, max_tokens: maxTokens, stream: false)

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

        return CompletionResult(
            content: content,
            model: json["model"] as? String ?? "",
            promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage?["completion_tokens"] as? Int ?? 0,
            sourceNode: mycellm?["node"] as? String ?? "",
            latencyMs: mycellm?["latency_ms"] as? Int ?? 0
        )
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
