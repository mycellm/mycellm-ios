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

    // MARK: - Helpers

    private static func json(_ obj: Any, status: HTTPResponse.Status = .ok) throws -> Response {
        let body = try JSONSerialization.data(withJSONObject: obj)
        return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: body)))
    }

    private static func error(_ msg: String, status: HTTPResponse.Status = .badRequest) throws -> Response {
        try json(["error": msg], status: status)
    }

    private static func parseBody(_ request: Request) async throws -> [String: Any] {
        let data = try await request.body.collect(upTo: 1024 * 1024)
        return (try? JSONSerialization.jsonObject(with: Data(buffer: data)) as? [String: Any]) ?? [:]
    }

    // MARK: - Start

    func start(port: Int = defaultPort, nodeService: NodeService) async throws {
        guard case .stopped = state else { return }
        state = .starting

        let router = Router()

        // ── Health ──
        router.get("/health") { _, _ -> Response in
            try Self.json(HealthRoute.response(node: nodeService))
        }

        // ── Node Status ──
        router.get("/v1/node/status") { _, _ -> Response in
            try Self.json(NodeRoutes.status(node: nodeService))
        }

        router.get("/v1/node/system") { _, _ -> Response in
            try Self.json(NodeRoutes.system())
        }

        // ── OpenAI Compatible ──
        router.get("/v1/models") { _, _ -> Response in
            try Self.json(OpenAIRoutes.listModels(manager: nodeService.modelManager))
        }

        router.post("/v1/chat/completions") { request, _ -> Response in
            let data = try await request.body.collect(upTo: 1024 * 1024)
            let req = try JSONDecoder().decode(OpenAIRoutes.ChatCompletionRequest.self, from: Data(buffer: data))

            let engine = nodeService.modelManager.engine

            if req.stream ?? false {
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
                let result = try await engine.complete(
                    messages: req.messages.map { ["role": $0.role, "content": $0.content] },
                    temperature: req.temperature ?? 0.7,
                    maxTokens: req.max_tokens ?? 2048
                )
                await MainActor.run {
                    nodeService.recordHTTPInference(model: req.model, tokens: result.promptTokens + result.completionTokens)
                }
                let response: [String: Any] = [
                    "choices": [["message": ["role": "assistant", "content": result.text], "index": 0, "finish_reason": "stop"]],
                    "usage": ["prompt_tokens": result.promptTokens, "completion_tokens": result.completionTokens, "total_tokens": result.promptTokens + result.completionTokens],
                    "model": req.model,
                ]
                return try Self.json(response)
            }
        }

        // ── Model Search & Suggestions ──
        router.get("/v1/node/models/suggested") { _, _ -> Response in
            try Self.json(ModelRoutes.suggestedModels())
        }

        router.get("/v1/node/models/search") { request, _ -> Response in
            let query = request.uri.queryParameters.get("q") ?? ""
            let results = await ModelRoutes.searchHuggingFace(query: query)
            return try Self.json(results)
        }

        // ── Model Management ──

        router.get("/v1/node/models/local") { _, _ -> Response in
            let mm = nodeService.modelManager
            let files: [[String: Any]] = mm.localFiles.map { f in
                [
                    "filename": f.filename,
                    "path": f.path,
                    "size_bytes": f.sizeBytes,
                    "size_gb": Double(f.sizeBytes) / 1_073_741_824.0,
                    "loaded": f.isLoaded,
                ]
            }
            return try Self.json(["model_dir": ModelManager.modelsDirectory.path, "files": files])
        }

        router.post("/v1/node/models/load") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let mm = nodeService.modelManager
            let backend = body["backend"] as? String ?? "llama.cpp"

            if backend == "openai" {
                guard let name = body["name"] as? String, !name.isEmpty,
                      let apiBase = body["api_base"] as? String, !apiBase.isEmpty else {
                    return try Self.error("name and api_base required for openai backend")
                }
                try await mm.loadAPIModel(
                    name: name,
                    apiBase: apiBase,
                    apiKey: body["api_key"] as? String ?? "",
                    apiModel: body["api_model"] as? String ?? name,
                    ctxLen: body["ctx_len"] as? Int ?? 4096
                )
                return try Self.json(["status": "loaded", "model": name, "backend": "openai"])
            } else {
                // llama.cpp — load from local path or filename
                let filename = body["model_path"] as? String ?? body["filename"] as? String ?? ""
                guard !filename.isEmpty else {
                    return try Self.error("model_path required for llama.cpp backend")
                }
                let scope = body["scope"] as? String ?? "home"
                guard let file = mm.localFiles.first(where: { $0.filename == URL(fileURLWithPath: filename).lastPathComponent || $0.path == filename }) else {
                    return try Self.error("Model file not found: \(filename)")
                }
                Task { try? await mm.loadModel(file: file, scope: scope) }
                return try Self.json(["status": "loading", "model": file.filename, "backend": "llama.cpp"])
            }
        }

        router.post("/v1/node/models/unload") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let modelName = body["model"] as? String ?? ""
            let mm = nodeService.modelManager
            if let model = mm.loadedModels.first(where: { $0.name == modelName || $0.filename == modelName }) {
                await mm.unloadModel(model)
                return try Self.json(["status": "unloaded", "model": modelName])
            }
            return try Self.error("Model not loaded: \(modelName)", status: .notFound)
        }

        router.get("/v1/node/models/load-status") { _, _ -> Response in
            let mm = nodeService.modelManager
            var statuses: [[String: Any]] = mm.loadedModels.map {
                ["name": $0.name, "status": "loaded", "error": NSNull()] as [String: Any]
            }
            if mm.isLoading, let name = mm.loadingModelName {
                statuses.append(["name": name, "status": "loading", "error": NSNull()])
            }
            if let err = mm.loadError {
                statuses.append(["name": mm.loadingModelName ?? "unknown", "status": "failed", "error": err])
            }
            return try Self.json(["statuses": statuses])
        }

        router.get("/v1/node/models/saved") { _, _ -> Response in
            let configs = nodeService.modelManager.savedAPIConfigs().map { c in
                [
                    "name": c.name,
                    "backend": "openai",
                    "api_base": c.apiBase,
                    "api_model": c.apiModel,
                    "api_key": c.apiKey.isEmpty ? "" : "***",
                    "ctx_len": c.ctxLen,
                    "loaded": nodeService.modelManager.loadedModels.contains(where: { $0.name == c.name }),
                ] as [String: Any]
            }
            return try Self.json(["configs": configs])
        }

        router.post("/v1/node/models/scope") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let modelName = body["model"] as? String ?? ""
            let scope = body["scope"] as? String ?? "home"
            let mm = nodeService.modelManager
            if let model = mm.loadedModels.first(where: { $0.name == modelName }) {
                mm.setScope(scope, for: model)
                return try Self.json(["status": "ok", "model": modelName, "scope": scope])
            }
            return try Self.error("Model not loaded: \(modelName)", status: .notFound)
        }

        router.post("/v1/node/models/remove-config") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let name = body["model"] as? String ?? ""
            nodeService.modelManager.removeAPIModel(name: name)
            return try Self.json(["status": "removed", "model": name])
        }

        router.post("/v1/node/models/delete-file") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let filename = body["filename"] as? String ?? ""
            let mm = nodeService.modelManager
            if let file = mm.localFiles.first(where: { $0.filename == filename }) {
                mm.deleteModel(file: file)
                return try Self.json(["status": "deleted", "filename": filename, "size_gb": Double(file.sizeBytes) / 1_073_741_824.0])
            }
            return try Self.error("File not found: \(filename)", status: .notFound)
        }

        // ── Relay Management ──

        router.get("/v1/node/relay") { _, _ -> Response in
            try Self.json(["relays": nodeService.relayManager.status()])
        }

        router.post("/v1/node/relay/add") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let url = body["url"] as? String ?? ""
            guard !url.isEmpty else { return try Self.error("url required") }
            let relay = try await nodeService.relayManager.add(
                url: url,
                name: body["name"] as? String ?? "",
                apiKey: body["api_key"] as? String ?? "",
                maxConcurrent: body["max_concurrent"] as? Int ?? 32
            )
            return try Self.json([
                "status": "added",
                "relay": ["url": relay.url, "name": relay.name, "online": relay.online, "error": relay.error, "models": relay.models] as [String: Any]
            ])
        }

        router.post("/v1/node/relay/remove") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let url = body["url"] as? String ?? ""
            nodeService.relayManager.remove(url: url)
            return try Self.json(["status": "removed", "url": url])
        }

        router.post("/v1/node/relay/refresh") { _, _ -> Response in
            await nodeService.relayManager.refreshAll()
            let total = nodeService.relayManager.relays.reduce(0) { $0 + $1.models.count }
            return try Self.json(["models_discovered": total, "relays": nodeService.relayManager.status()])
        }

        // ── Credits ──

        router.get("/v1/node/credits") { _, _ -> Response in
            let ledger = nodeService.creditLedger
            let balance = await ledger.balance
            let earned = await ledger.totalEarned
            let spent = await ledger.totalSpent
            return try Self.json(["balance": balance, "earned": earned, "spent": spent])
        }

        router.get("/v1/node/credits/tier") { _, _ -> Response in
            let balance = await nodeService.creditLedger.balance
            let receipts = await nodeService.creditLedger.pendingReceiptCount
            let tier: String
            let label: String
            let access: String
            if balance >= 50 {
                tier = "power"; label = "Power Seeder"; access = "All model tiers"
            } else if balance >= 10 {
                tier = "contributor"; label = "Contributor"; access = "Tier 1 + Tier 2 models"
            } else {
                tier = "free"; label = "Free Tier"; access = "Tier 1 models only"
            }
            return try Self.json([
                "tier": tier, "label": label, "access": access, "balance": balance,
                "receipts": receipts,
                "thresholds": ["free": 0, "contributor": 10, "power": 50] as [String: Any]
            ])
        }

        router.get("/v1/node/credits/history") { request, _ -> Response in
            let limit = Int(request.uri.queryParameters.get("limit") ?? "50") ?? 50
            let txns = await nodeService.creditLedger.recentTransactions(limit: limit)
            let list: [[String: Any]] = txns.map { t in
                [
                    "counterparty": t.counterparty,
                    "amount": t.amount,
                    "direction": t.direction.rawValue,
                    "reason": t.reason,
                    "timestamp": t.timestamp.timeIntervalSince1970,
                    "request_id": t.requestId,
                ]
            }
            return try Self.json(["transactions": list])
        }

        // ── Start Server ──

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
