import Foundation

/// OpenAI-compatible API routes: /v1/chat/completions, /v1/models
/// OpenAI-compatible API route handlers.
enum OpenAIRoutes {
    /// GET /v1/models — list available models
    static func listModels(manager: ModelManager) -> [String: Any] {
        let models = manager.loadedModels.map { model -> [String: Any] in
            [
                "id": model.name,
                "object": "model",
                "created": Int(model.loadedAt.timeIntervalSince1970),
                "owned_by": "local",
            ]
        }
        return ["object": "list", "data": models]
    }

    /// POST /v1/chat/completions request body shape
    struct ChatCompletionRequest: Codable, Sendable {
        let model: String
        let messages: [Message]
        var temperature: Double? = 0.7
        var max_tokens: Int? = 2048
        var stream: Bool? = false

        struct Message: Codable, Sendable {
            let role: String
            let content: String
        }
    }
}
