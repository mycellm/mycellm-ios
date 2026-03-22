import Foundation
import Hummingbird

/// Local HTTP server on configurable port using Hummingbird 2.
/// Exposes OpenAI-compatible API for local and network consumers.
actor HTTPServer {
    static let defaultPort: Int = 8420

    enum State: Sendable {
        case stopped
        case starting
        case running(Int)
        case error(String)
    }

    private(set) var state: State = .stopped
    private var serverTask: Task<Void, Error>?

    func start(port: Int = defaultPort, nodeService: NodeService) async throws {
        guard case .stopped = state else { return }
        state = .starting

        let router = Router()

        // Health
        router.get("/health") { _, _ -> Response in
            let body = try JSONSerialization.data(withJSONObject: HealthRoute.response(node: nodeService))
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
        }

        // Node status
        router.get("/v1/node/status") { _, _ -> Response in
            let body = try JSONSerialization.data(withJSONObject: NodeRoutes.status(node: nodeService))
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
        }

        // System info
        router.get("/v1/node/system") { _, _ -> Response in
            let body = try JSONSerialization.data(withJSONObject: NodeRoutes.system())
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
        }

        // List models (OpenAI compatible)
        router.get("/v1/models") { _, _ -> Response in
            let body = try JSONSerialization.data(withJSONObject: OpenAIRoutes.listModels(manager: nodeService.modelManager))
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
        }

        // Chat completions (OpenAI compatible)
        router.post("/v1/chat/completions") { request, _ -> Response in
            let data = try await request.body.collect(upTo: 1024 * 1024)
            let req = try JSONDecoder().decode(OpenAIRoutes.ChatCompletionRequest.self, from: Data(buffer: data))

            let engine = nodeService.modelManager.engine

            if req.stream ?? false {
                // SSE streaming
                let stream = await engine.stream(
                    messages: req.messages.map { ["role": $0.role, "content": $0.content] },
                    temperature: req.temperature ?? 0.7,
                    maxTokens: req.max_tokens ?? 2048
                )
                let sseStream = AsyncStream<ByteBuffer> { continuation in
                    Task {
                        for try await chunk in stream {
                            let event: [String: Any] = [
                                "choices": [["delta": ["content": chunk], "index": 0, "finish_reason": NSNull()]]
                            ]
                            if let json = try? JSONSerialization.data(withJSONObject: event) {
                                let line = "data: \(String(data: json, encoding: .utf8)!)\n\n"
                                continuation.yield(ByteBuffer(string: line))
                            }
                        }
                        continuation.yield(ByteBuffer(string: "data: [DONE]\n\n"))
                        continuation.finish()
                    }
                }
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                    body: .init(asyncSequence: sseStream)
                )
            } else {
                // Non-streaming
                let result = try await engine.complete(
                    messages: req.messages.map { ["role": $0.role, "content": $0.content] },
                    temperature: req.temperature ?? 0.7,
                    maxTokens: req.max_tokens ?? 2048
                )
                let response: [String: Any] = [
                    "choices": [["message": ["role": "assistant", "content": result.text], "index": 0, "finish_reason": "stop"]],
                    "usage": ["prompt_tokens": result.promptTokens, "completion_tokens": result.completionTokens, "total_tokens": result.promptTokens + result.completionTokens],
                    "model": req.model,
                ]
                let body = try JSONSerialization.data(withJSONObject: response)
                return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
            }
        }

        // Suggested models
        router.get("/v1/node/models/suggested") { _, _ -> Response in
            let body = try JSONSerialization.data(withJSONObject: ModelRoutes.suggestedModels())
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
        }

        // Search models
        router.get("/v1/node/models/search") { request, _ -> Response in
            let query = request.uri.queryParameters.get("q") ?? ""
            let results = await ModelRoutes.searchHuggingFace(query: query)
            let body = try JSONSerialization.data(withJSONObject: results)
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: port))
        )

        state = .running(port)
        serverTask = Task {
            try await app.runService()
        }
    }

    func stop() async {
        serverTask?.cancel()
        serverTask = nil
        state = .stopped
    }
}
