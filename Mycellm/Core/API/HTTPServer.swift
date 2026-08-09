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

        let router = Router(context: NodeRequestContext.self)

        // ⚠️ ADDED BEFORE ANY ROUTE. Middleware order is registration order in
        // Hummingbird, so a gate declared after the routes it guards does not
        // guard them. Only `/v1/node/**` is affected — see NodeAuth for why the
        // inference paths stay open.
        router.middlewares.add(NodeAuthMiddleware())

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

        router.get("/v1/models/capabilities") { _, _ -> Response in
            try Self.json(OpenAIRoutes.listCapabilities(manager: nodeService.modelManager))
        }

        router.post("/v1/chat/completions") { request, _ -> Response in
            let data = try await request.body.collect(upTo: 1024 * 1024)
            let req = try JSONDecoder().decode(OpenAIRoutes.ChatCompletionRequest.self, from: Data(buffer: data))

            let engine = nodeService.modelManager.engine
            let modelName = req.model
            let reasoningExclude = OpenAIRoutes.resolveReasoningExclude(req.reasoning)
            let requestedTools = req.tools ?? []
            // Tools + streaming aren't combined yet — the parser needs the
            // full output to identify tool-call markup. Fall back to
            // non-streaming when tools are present, matching Python's
            // behaviour for v0.3.0.
            let toolsForceNonStream = !requestedTools.isEmpty
            // Engine accepts dict messages — we still pass content as the
            // canonical text; tool_calls / tool_call_id / name carried via
            // the typed shape but flattened to plain strings here until
            // the backends understand tool-call message roles natively.
            // Build multimodal messages once. Requests carrying images route to
            // the engine's VLM path; text-only requests keep the exact
            // [[String:String]] path below (no behavior change).
            let mmMessages = req.messages.map { $0.asMultimodal() }
            let engineMessages: [[String: String]] = mmMessages.asTextMessages
            let hasImages = mmMessages.hasImages

            if (req.stream ?? false) && !toolsForceNonStream {
                let stream = hasImages
                    ? await engine.stream(
                        multimodal: mmMessages,
                        temperature: req.temperature ?? 0.7,
                        maxTokens: req.resolvedMaxTokens)
                    : await engine.stream(
                        messages: engineMessages,
                        temperature: req.temperature ?? 0.7,
                        maxTokens: req.resolvedMaxTokens)
                // Per-stream <think>-splitter routes tokens to delta.content
                // vs delta.reasoning_content. No-op for non-thinking models.
                let splitter = StreamingThinkSplitter(modelName: modelName)
                let sseStream = AsyncStream<ByteBuffer> { continuation in
                    Task {
                        func emit(_ delta: [String: Any], finish: Any = NSNull()) {
                            let event: [String: Any] = [
                                "choices": [["delta": delta, "index": 0, "finish_reason": finish]],
                                "model": modelName,
                                "object": "chat.completion.chunk",
                            ]
                            if let json = try? JSONSerialization.data(withJSONObject: event),
                               let s = String(data: json, encoding: .utf8) {
                                continuation.yield(ByteBuffer(string: "data: \(s)\n\n"))
                            }
                        }
                        for try await chunk in stream {
                            for (kind, piece) in splitter.feed(chunk) {
                                switch kind {
                                case .content:
                                    emit(["content": piece])
                                case .reasoning where !reasoningExclude:
                                    emit(["reasoning_content": piece])
                                default:
                                    break  // dropped: reasoning while excluded
                                }
                            }
                        }
                        // Drain at end of stream (handles unclosed <think>)
                        for (kind, piece) in splitter.flush() {
                            switch kind {
                            case .content:
                                emit(["content": piece])
                            case .reasoning where !reasoningExclude:
                                emit(["reasoning_content": piece])
                            default:
                                break
                            }
                        }
                        emit([:], finish: "stop")
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
                let result = hasImages
                    ? try await engine.complete(
                        multimodal: mmMessages,
                        temperature: req.temperature ?? 0.7,
                        maxTokens: req.resolvedMaxTokens,
                        tools: requestedTools)
                    : try await engine.complete(
                        messages: engineMessages,
                        temperature: req.temperature ?? 0.7,
                        maxTokens: req.resolvedMaxTokens,
                        tools: requestedTools)
                await MainActor.run {
                    nodeService.recordHTTPInference(model: req.model, tokens: result.promptTokens + result.completionTokens)
                }
                let (content, reasoning) = ReasoningDialects.splitReasoning(result.text, modelName: modelName)
                var message: [String: Any] = ["role": "assistant", "content": content]
                if !reasoning.isEmpty && !reasoningExclude {
                    message["reasoning_content"] = reasoning
                }
                if !result.toolCalls.isEmpty {
                    // OpenAI shape: tool_calls is an array of
                    // {id, type, function: {name, arguments}}.
                    message["tool_calls"] = result.toolCalls.enumerated().map { i, c -> [String: Any] in
                        [
                            "id": "call_\(i)_\(c.name)",
                            "type": "function",
                            "function": ["name": c.name, "arguments": c.arguments],
                        ]
                    }
                }
                let finishReason: String = result.toolCalls.isEmpty ? "stop" : "tool_calls"
                let response: [String: Any] = [
                    "choices": [["message": message, "index": 0, "finish_reason": finishReason]],
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
            let format = request.uri.queryParameters.get("format").map { String($0) } ?? "mlx"
            let results = await ModelRoutes.searchHuggingFace(query: query, format: format)
            return try Self.json(results)
        }

        // ── Downloads ──
        //
        // Node parity: the Python node can fetch a model it doesn't have, and
        // until now an iOS node could not — every model had to arrive through
        // the UI (GGUF) or the Files app (MLX). That made an iOS node something
        // you had to walk over to, which is the opposite of what a node is.

        router.post("/v1/node/models/download") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            guard let repoId = body["repo_id"] as? String, !repoId.isEmpty else {
                return try Self.error("repo_id required")
            }

            // Explicit `format` wins; otherwise a filename means the caller has
            // picked one GGUF file out of a repo, and no filename means take the
            // repo as a model — which is what MLX is.
            let filename = body["filename"] as? String
            let format = (body["format"] as? String)
                ?? (filename?.isEmpty == false ? "gguf" : "mlx")

            if format == "gguf" {
                guard let filename, !filename.isEmpty else {
                    return try Self.error("filename required for gguf downloads")
                }
                await MainActor.run {
                    nodeService.modelDownloader.download(repoId: repoId, filename: filename)
                }
                return try Self.json([
                    "status": "downloading", "repo_id": repoId,
                    "filename": filename, "format": "gguf",
                ])
            }

            // Resolve the plan up front so a bad repo, a non-MLX repo or a
            // device that hasn't the space fails HERE, with a reason the caller
            // can act on — rather than as a background task that silently ends
            // in .failed and has to be discovered by polling.
            do {
                let assets = try await MLXRepo.plan(repoId: repoId)
                let total = assets.reduce(Int64(0)) { $0 + $1.size }
                let free = MLXRepo.freeBytes()
                guard free > total + 500 * 1024 * 1024 else {
                    return try Self.error(MLXRepo.Failure
                        .insufficientSpace(needed: total, free: free).localizedDescription)
                }
                let name = body["name"] as? String
                let id = await MainActor.run {
                    nodeService.modelDownloader.downloadRepo(repoId: repoId, name: name)
                }
                return try Self.json([
                    "status": "downloading",
                    "download_id": id.uuidString,
                    "repo_id": repoId,
                    "name": name ?? MLXRepo.directoryName(for: repoId),
                    "format": "mlx",
                    "files": assets.count,
                    "total_bytes": total,
                ])
            } catch {
                return try Self.error(error.localizedDescription)
            }
        }

        router.get("/v1/node/models/downloads") { _, _ -> Response in
            let (files, repos) = await MainActor.run {
                (nodeService.modelDownloader.activeDownloads,
                 nodeService.modelDownloader.repoDownloads)
            }
            return try Self.json([
                "downloads": files.map { d in
                    [
                        "repo_id": d.repoId, "filename": d.filename, "format": "gguf",
                        "state": d.state.rawValue.lowercased(), "progress": d.progress,
                        "bytes_downloaded": d.bytesDownloaded, "total_bytes": d.totalBytes,
                        "bytes_per_second": d.bytesPerSecond,
                    ] as [String: Any]
                },
                "repo_downloads": repos.map { d in
                    [
                        "download_id": d.id.uuidString, "repo_id": d.repoId,
                        "name": d.name, "format": "mlx",
                        "state": d.state.rawValue.lowercased(), "progress": d.progress,
                        "bytes_downloaded": d.bytesDownloaded, "total_bytes": d.totalBytes,
                        "bytes_per_second": d.bytesPerSecond,
                        "error": d.error ?? "",
                    ] as [String: Any]
                },
            ])
        }

        router.post("/v1/node/models/download/cancel") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            guard let idString = body["download_id"] as? String, let id = UUID(uuidString: idString) else {
                return try Self.error("download_id required")
            }
            await MainActor.run { nodeService.modelDownloader.cancelRepo(id: id) }
            return try Self.json(["status": "cancelled", "download_id": idString])
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
                    // A caller choosing what to load needs this: an MLX entry is
                    // a directory, a GGUF entry a file, and they aren't
                    // interchangeable in a load request.
                    "format": f.format,
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
                // HTTP handlers are non-isolated; can't touch @MainActor
                // Preferences.shared. Read UserDefaults directly + apply
                // the same memory-tiered fallback Preferences uses, so
                // /v1/node/models/load with no explicit ctx_len doesn't
                // OOM Metal on small phones.
                let memDefault: Int = {
                    let gb = HardwareInfo.totalMemoryGB
                    if gb >= 14 { return 16384 }
                    if gb >= 10 { return 8192 }
                    return 4096
                }()
                let userDefault = UserDefaults.standard.integer(forKey: "default_ctx_len")
                let resolvedCtxLen = (body["ctx_len"] as? Int) ?? (userDefault > 0 ? userDefault : memDefault)
                try await mm.loadAPIModel(
                    name: name,
                    apiBase: apiBase,
                    apiKey: body["api_key"] as? String ?? "",
                    apiModel: body["api_model"] as? String ?? name,
                    ctxLen: resolvedCtxLen
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
                // ⚠️ REPORT THE FORMAT WE ACTUALLY DETECTED. `backend` defaults
                // to "llama.cpp" for back-compat, but ModelManager.loadModel
                // dispatches on ModelFormat.detect(path:) regardless — so an MLX
                // directory loads correctly and used to be reported as
                // llama.cpp, telling every caller the node was running a backend
                // it wasn't. The load path needed no MLX branch; the answer did.
                let detected = ModelFormat.detect(path: file.path) == .mlx ? "mlx" : "llama.cpp"
                return try Self.json(["status": "loading", "model": file.filename, "backend": detected])
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
            await MainActor.run { nodeService.modelManager.removeAPIModel(name: name) }
            return try Self.json(["status": "removed", "model": name])
        }

        router.post("/v1/node/models/delete-file") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let filename = body["filename"] as? String ?? ""
            let mm = nodeService.modelManager
            if let file = mm.localFiles.first(where: { $0.filename == filename }) {
                await MainActor.run { mm.deleteModel(file: file) }
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
