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

        // ── Metrics ──
        //
        // Mounted at the root, not under /v1/node, because that is where Python
        // serves it and where a Prometheus scrape config already points.
        router.get("/metrics") { _, _ -> Response in
            let text = await NodeMetrics.render(node: nodeService)
            return Response(
                status: .ok,
                headers: [.contentType: NodeMetrics.contentType],
                body: .init(byteBuffer: ByteBuffer(string: text))
            )
        }

        // ── Node Status ──
        router.get("/v1/node/status") { _, _ -> Response in
            try Self.json(await NodeRoutes.status(node: nodeService))
        }

        router.get("/v1/node/system") { _, _ -> Response in
            try Self.json(NodeRoutes.system())
        }

        router.get("/v1/node/version") { _, _ -> Response in
            try Self.json(await NodeRoutes.version())
        }

        router.get("/v1/node/peers") { _, _ -> Response in
            try Self.json(NodeRoutes.peers(node: nodeService))
        }

        router.get("/v1/node/connections") { _, _ -> Response in
            try Self.json(NodeRoutes.connections(node: nodeService))
        }

        // ── Activity & Logs ──

        router.get("/v1/node/activity") { request, _ -> Response in
            let activity = nodeService.stats.activity
            let limit = Int(request.uri.queryParameters.get("limit") ?? "50") ?? 50
            let type = request.uri.queryParameters.get("type").map { String($0) }
            return try Self.json([
                "events": activity.recent(limit: limit, eventType: type),
                "stats": activity.stats(),
                "sparklines": [
                    "requests": activity.sparkline("requests", minutes: 30),
                    "tokens": activity.sparkline("tokens", minutes: 30),
                    "credits_earned": activity.sparkline("credits_earned", minutes: 30),
                    "credits_spent": activity.sparkline("credits_spent", minutes: 30),
                ] as [String: Any],
            ])
        }

        router.get("/v1/node/activity/stream") { _, _ -> Response in
            SSEResponse.stream(nodeService.stats.activity.subscribe()) { $0.asDict }
        }

        router.get("/v1/node/logs") { request, _ -> Response in
            let limit = Int(request.uri.queryParameters.get("limit") ?? "100") ?? 100
            return try Self.json(["logs": LogBroadcaster.shared.recent(limit: limit)])
        }

        router.get("/v1/node/logs/stream") { _, _ -> Response in
            SSEResponse.stream(LogBroadcaster.shared.subscribe()) { $0.asDict }
        }

        // ── OpenAI Compatible ──
        router.get("/v1/models") { _, _ -> Response in
            try Self.json(OpenAIRoutes.listModels(manager: nodeService.modelManager))
        }

        router.get("/v1/models/capabilities") { _, _ -> Response in
            try Self.json(OpenAIRoutes.listCapabilities(manager: nodeService.modelManager))
        }

        // ⚠️ REGISTERED AFTER /v1/models/capabilities. Hummingbird matches a
        // literal segment ahead of a parameter, so the order is not load-bearing
        // for correctness — but keeping the specific route above the wildcard
        // keeps it obvious that "capabilities" is not a model id.
        router.get("/v1/models/:model_id") { _, context -> Response in
            let id = context.parameters.get("model_id").map { String($0) } ?? ""
            guard let model = OpenAIRoutes.retrieveModel(id: id, manager: nodeService.modelManager) else {
                return try Self.error("not found", status: .notFound)
            }
            return try Self.json(model)
        }

        router.post("/v1/embeddings") { request, _ -> Response in
            let data = try await request.body.collect(upTo: 1024 * 1024)

            func fail(_ status: HTTPResponse.Status, _ message: String, _ type: String, _ code: String) throws -> Response {
                try Self.json(OpenAIRoutes.errorBody(message, type: type, code: code), status: status)
            }

            // ⚠️ THREE DISTINCT FAILURES, THREE DISTINCT MESSAGES. Collapsing
            // them (as a single `?? EmbeddingsRequest()` fallback did) reports
            // every malformed request as "token array not supported" — advice
            // that is wrong for two of the three and unactionable for all of
            // them. A caller has to be able to tell "your JSON is broken" from
            // "you omitted input" from "send strings, not tokens".
            guard let req = try? JSONDecoder().decode(
                OpenAIRoutes.EmbeddingsRequest.self, from: Data(buffer: data))
            else {
                return try fail(.badRequest,
                    "Malformed request body — expected a JSON object.",
                    "invalid_request_error", "invalid_request")
            }
            guard let input = req.input else {
                return try fail(.badRequest,
                    "'input' must be a non-empty string or list of strings.",
                    "invalid_request_error", "invalid_input")
            }
            guard let texts = input.texts else {
                return try fail(.badRequest,
                    "Token array input is not supported — send 'input' as a string or list of strings.",
                    "invalid_request_error", "invalid_input")
            }
            guard !texts.isEmpty else {
                return try fail(.badRequest,
                    "'input' must be a non-empty string or list of strings.",
                    "invalid_request_error", "invalid_input")
            }

            // A device serves one model at a time, so resolution is simply
            // "is the loaded model an embedding model" — the multi-candidate
            // resolve_model_name() Python needs has nothing to choose between
            // here. An explicit name that isn't the loaded one still 400s with
            // model_not_found, as Python does.
            let mm = nodeService.modelManager
            let requested = req.model == "auto" ? "" : req.model
            guard let loaded = mm.loadedModels.first else {
                return try fail(.badRequest, "No models loaded.",
                    "invalid_request_error", "model_not_found")
            }
            if !requested.isEmpty, requested != loaded.name, requested != loaded.filename {
                return try fail(.badRequest,
                    "Model '\(req.model)' not found. No loaded model serves embeddings.",
                    "invalid_request_error", "model_not_found")
            }

            do {
                let result = try await mm.engine.embed(texts)
                return try Self.json(OpenAIRoutes.embeddingsBody(result, model: loaded.name))
            } catch let error as MycellmError {
                switch error {
                case .embeddingsNotSupported(let message):
                    return try fail(.badRequest, message,
                        "invalid_request_error", "embeddings_not_supported")
                case .modelNotLoaded(let message):
                    return try fail(.badRequest, message,
                        "invalid_request_error", "model_not_found")
                default:
                    nodeService.recordHTTPInferenceFailure(
                        model: loaded.name, error: error.localizedDescription)
                    return try fail(.internalServerError, error.localizedDescription,
                        "server_error", "inference_error")
                }
            } catch {
                nodeService.recordHTTPInferenceFailure(
                    model: loaded.name, error: error.localizedDescription)
                return try fail(.internalServerError, error.localizedDescription,
                    "server_error", "inference_error")
            }
        }

        router.post("/v1/chat/completions") { request, _ -> Response in
            let data = try await request.body.collect(upTo: 1024 * 1024)
            let req = try JSONDecoder().decode(OpenAIRoutes.ChatCompletionRequest.self, from: Data(buffer: data))

            let engine = nodeService.modelManager.engine
            let modelName = req.model

            // ⚠️ AN EMBEDDING MODEL CANNOT GENERATE, AND FAILS SILENTLY IF ASKED.
            // MiniLM/BERT-family models are encoder-only: there is no
            // language-modelling head, so the logits are meaningless and
            // sampling wanders into the vocabulary's reserved `[unusedNN]`
            // slots. The node returned all of that as HTTP 200 with
            // finish_reason "stop" — a success no caller could tell from a
            // real answer.
            //
            // The classification already existed and was already correct
            // (/v1/models/capabilities reports tags ["embedding"]); nothing
            // consulted it before generating. This is the mirror of the
            // /v1/embeddings guard: that one refuses embeddings on a chat
            // model, this one refuses chat on an embedding model.
            if let serving = await MainActor.run(body: {
                nodeService.modelManager.loadedModels.first {
                    $0.name == modelName || $0.filename == modelName
                }?.name ?? nodeService.modelManager.loadedModels.first?.name
            }), EmbeddingModels.isEmbeddingModel(serving) {
                return try Self.json(OpenAIRoutes.errorBody(
                    "\(serving) is an embedding model and cannot generate text. "
                    + "Load a chat model, or send this request to /v1/embeddings.",
                    type: "invalid_request_error",
                    code: "model_not_chat_capable"), status: .badRequest)
            }

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
                let result: InferenceResult
                do {
                    result = hasImages
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
                } catch {
                    // Recorded before rethrowing so `total_errors`, `errors_5min`
                    // and the error sparkline reflect reality — until now a
                    // failed completion left no trace anywhere in the API.
                    // No MainActor hop: unlike recordHTTPInference this touches
                    // no @Observable state, only the lock-guarded tracker.
                    nodeService.recordHTTPInferenceFailure(
                        model: modelName, error: error.localizedDescription)
                    throw error
                }
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

        // GET /v1/node/models/search/{repo_id}/files — the repo id contains a
        // slash (`org/name`), so it is matched with a catch-all and the
        // trailing "/files" stripped back off. `:param` would only capture
        // "org" and look up the wrong repo.
        router.get("/v1/node/models/search/**") { _, context -> Response in
            let captured = context.parameters.getCatchAll().joined(separator: "/")
            guard captured.hasSuffix("/files") else {
                return try Self.error("not found", status: .notFound)
            }
            let repoId = String(captured.dropLast("/files".count))
            return try Self.json(await ModelRoutes.repoFiles(repoId: repoId))
        }

        // ── Downloads ──
        //
        // Node parity: the Python node can fetch a model it doesn't have, and
        // until now an iOS node could not — every model had to arrive through
        // the UI (GGUF) or the Files app (MLX). That made an iOS node something
        // you had to walk over to, which is the opposite of what a node is.

        router.post("/v1/node/models/download") { request, _ -> Response in
            let body = try await Self.parseBody(request)

            // ── Arbitrary URL ────────────────────────────────────────────
            // For models that aren't on Hugging Face: an internal mirror, a
            // private build, an admin coordinating an install across a fleet.
            //
            // ⚠️ `sha256` IS REQUIRED HERE AND NOWHERE ELSE. Every other
            // download is checked against a hash the node can look up for
            // itself (HF publishes `lfs.oid`). A URL has no such attestation,
            // so without a digest this would be the only way to place
            // unverified weights on a device — on the say-so of whoever holds
            // the management key. Requiring the caller to commit to a hash in
            // advance keeps the invariant that everything on disk was verified
            // against something stated up front.
            // ── MLX manifest ─────────────────────────────────────────────
            // An MLX model is a directory, so the admin-install form is
            // per-file: each entry names its own URL and digest. Same staging,
            // resume and atomic publish as a Hugging Face repo — only the
            // source and the verification differ.
            if let files = body["files"] as? [[String: Any]], !files.isEmpty {
                guard let name = (body["name"] as? String)?
                        .trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      !name.contains("/") else {
                    return try Self.error("name required for a manifest install")
                }
                var assets: [MLXRepo.Asset] = []
                for f in files {
                    guard let path = f["path"] as? String, !path.isEmpty, !path.contains("..") else {
                        return try Self.error("each file needs a path")
                    }
                    guard let u = f["url"] as? String,
                          let parsed = URL(string: u),
                          parsed.scheme?.lowercased() == "https" else {
                        return try Self.error("\(path): url must be an absolute https URL")
                    }
                    guard let sha = (f["sha256"] as? String)?
                            .trimmingCharacters(in: .whitespaces).lowercased(),
                          sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else {
                        return try Self.error("\(path): sha256 required — 64 hex characters")
                    }
                    let size = (f["size"] as? Int64) ?? Int64(f["size"] as? Int ?? 0)
                    assets.append(MLXRepo.Asset(path: path, size: size, url: u, sha256: sha))
                }
                // The scanner calls a directory loadable when it holds
                // config.json and any .safetensors — a manifest missing either
                // publishes something the picker offers and the engine cannot
                // load, so refuse it up front rather than after the download.
                guard assets.contains(where: { $0.path.hasSuffix(".safetensors") }),
                      assets.contains(where: { $0.path == "config.json" }) else {
                    return try Self.error(
                        "manifest must include config.json and at least one .safetensors file")
                }

                let total = assets.reduce(Int64(0)) { $0 + $1.size }
                let allow = (body["allow_expensive"] as? Bool) ?? false
                if case .refused(let network) = DownloadPolicy.decide(
                    connectivity: nodeService.connectivity, override: allow) {
                    return try Self.json([
                        "error": [
                            "code": "expensive_network", "network": network,
                            "estimated_bytes": total,
                            "message": DownloadPolicy.refusalMessage(network: network, bytes: total),
                        ] as [String: Any],
                    ], status: .conflict)
                }

                let id = await MainActor.run {
                    nodeService.modelDownloader.downloadManifest(
                        assets: assets, name: name, allowExpensive: allow)
                }
                return try Self.json([
                    "status": "downloading", "download_id": id.uuidString,
                    "name": name, "format": "mlx",
                    "files": assets.count, "total_bytes": total,
                ])
            }

            if let urlString = body["url"] as? String, !urlString.isEmpty {
                guard let parsed = URL(string: urlString),
                      let scheme = parsed.scheme?.lowercased(), scheme == "https" else {
                    return try Self.error("url must be an absolute https URL")
                }
                guard let sha256 = (body["sha256"] as? String)?
                        .trimmingCharacters(in: .whitespaces).lowercased(),
                      sha256.count == 64,
                      sha256.allSatisfy({ $0.isHexDigit }) else {
                    return try Self.error(
                        "sha256 required for url downloads — 64 hex characters of the file's digest")
                }
                let filename = (body["filename"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 } ?? parsed.lastPathComponent
                // ⚠️ `/` ALONE IS NOT ENOUGH. "." and ".." contain no slash and
                // sailed through, resolving the destination to the models
                // directory itself or its parent. The write then fails on a
                // directory rather than escaping, but the manifest branch
                // rejects ".." properly and these two must not disagree about
                // what a safe name is. A leading dot is refused as well — it
                // covers both of those and keeps a caller from writing over
                // `.staging/`, which is where in-flight downloads live.
                guard !filename.contains("/"),
                      ModelDownloader.safeDestinationName(filename) != nil else {
                    return try Self.error(
                        "filename must be a plain file name — no '/', no '..', no leading '.'")
                }

                let decision = DownloadPolicy.decide(
                    connectivity: nodeService.connectivity,
                    override: (body["allow_expensive"] as? Bool) ?? false)
                if case .refused(let network) = decision {
                    return try Self.json([
                        "error": [
                            "code": "expensive_network",
                            "network": network,
                            "estimated_bytes": 0,
                            "message": DownloadPolicy.refusalMessage(network: network, bytes: 0),
                        ] as [String: Any],
                    ], status: .conflict)
                }

                let downloadId = await MainActor.run {
                    nodeService.modelDownloader.download(
                        url: urlString, filename: filename, sha256: sha256,
                        allowExpensive: (body["allow_expensive"] as? Bool) ?? false)
                }
                // Hand back the id at start, so a caller can abort without
                // having to list downloads and match on filename first.
                return try Self.json([
                    "status": "downloading", "url": urlString,
                    "download_id": downloadId?.uuidString ?? "",
                    "filename": filename, "format": "gguf", "sha256": sha256,
                ])
            }

            guard let repoId = body["repo_id"] as? String, !repoId.isEmpty else {
                return try Self.error("repo_id, url, or files (manifest) required")
            }

            // Explicit `format` wins; otherwise a filename means the caller has
            // picked one GGUF file out of a repo, and no filename means take the
            // repo as a model — which is what MLX is.
            let filename = body["filename"] as? String
            let format = (body["format"] as? String)
                ?? (filename?.isEmpty == false ? "gguf" : "mlx")

            // ⚠️ A CONFIRMATION DIALOG CANNOT GATE THIS. The obvious answer to
            // "don't spend a user's cellular data on a 4 GB model" is a scary
            // modal, and it does not work here: this is an API, and the caller
            // is the dashboard, a fleet tool or a script, with nobody at the
            // device to tap anything. So the node enforces the policy itself
            // and reports a refusal the caller can act on — which is also
            // exactly what the UI needs to render a confirmation with the real
            // number in it.
            let allowExpensive = (body["allow_expensive"] as? Bool) ?? false
            let decision = DownloadPolicy.decide(
                connectivity: nodeService.connectivity, override: allowExpensive)

            if format == "gguf" {
                guard let filename, !filename.isEmpty else {
                    return try Self.error("filename required for gguf downloads")
                }
                // A repo path may contain directories; the name it writes may
                // not walk out of the models directory.
                guard ModelDownloader.safeDestinationName(filename) != nil else {
                    return try Self.error(
                        "filename must not resolve outside the models directory")
                }
                if case .refused(let network) = decision {
                    // GGUF size isn't known without a HEAD; report 0 rather than
                    // guess, and let the message carry the reason.
                    return try Self.json([
                        "error": [
                            "code": "expensive_network",
                            "network": network,
                            "estimated_bytes": 0,
                            "message": DownloadPolicy.refusalMessage(network: network, bytes: 0),
                        ] as [String: Any],
                    ], status: .conflict)
                }
                let downloadId = await MainActor.run {
                    nodeService.modelDownloader.download(
                        repoId: repoId, filename: filename, allowExpensive: allowExpensive)
                }
                return try Self.json([
                    "status": "downloading", "repo_id": repoId,
                    "download_id": downloadId?.uuidString ?? "",
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
                // Refused *after* planning, so the caller is told how big the
                // thing it asked for actually is — the number is the whole
                // point of refusing out loud instead of just failing. The plan
                // fetch is a few hundred bytes of JSON and is not itself
                // subject to the policy.
                if case .refused(let network) = decision {
                    return try Self.json([
                        "error": [
                            "code": "expensive_network",
                            "network": network,
                            "estimated_bytes": total,
                            "message": DownloadPolicy.refusalMessage(network: network, bytes: total),
                        ] as [String: Any],
                    ], status: .conflict)
                }
                let name = body["name"] as? String
                let id = await MainActor.run {
                    nodeService.modelDownloader.downloadRepo(
                        repoId: repoId, name: name, allowExpensive: allowExpensive)
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
                        // `download_id` is what downloads/abort takes. Omitting
                        // it here made every file download uncancellable.
                        "download_id": d.id.uuidString,
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

        // ⚠️ THE CANONICAL PATH IS `downloads/abort`, NOT `download/cancel`.
        // Python has served `POST /v1/node/models/downloads/abort` since the
        // route existed; iOS shipped `download/cancel` for the same operation,
        // so the dashboard's cancel button did nothing against an iOS node —
        // a 404 the UI had no reason to expect. The Python spelling wins
        // because it is the one every other node and client already uses.
        //
        // The old path stays registered as a deprecated alias: it shipped in
        // build 18, and silently 404ing a client that already adopted it would
        // trade one broken cancel button for another.
        // ⚠️ BOTH COLLECTIONS, NOT JUST `repoDownloads`. A file download and an
        // MLX repo download live in different arrays with different cancel
        // calls, and this only ever looked in the repo one — so a GGUF download
        // (including every URL install, which lands in the same array) could be
        // started through the API and then never stopped through it. The
        // listing compounded it by omitting `download_id` for file downloads,
        // so there was no value a caller could even send here.
        let abortDownload: @Sendable (Request) async throws -> Response = { request in
            let body = try await Self.parseBody(request)
            guard let idString = body["download_id"] as? String, let id = UUID(uuidString: idString) else {
                return try Self.error("download_id required")
            }
            let cancelled = await MainActor.run { () -> Bool in
                let downloader = nodeService.modelDownloader
                if downloader.repoDownloads.contains(where: { $0.id == id }) {
                    downloader.cancelRepo(id: id)
                    return true
                }
                if downloader.activeDownloads.contains(where: { $0.id == id }) {
                    downloader.cancelDownload(id: id)
                    return true
                }
                return false
            }
            guard cancelled else {
                return try Self.error("Unknown download_id", status: .notFound)
            }
            return try Self.json(["status": "aborted", "download_id": idString])
        }

        router.post("/v1/node/models/downloads/abort") { request, _ -> Response in
            try await abortDownload(request)
        }

        router.post("/v1/node/models/download/cancel") { request, _ -> Response in
            try await abortDownload(request)
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

        router.post("/v1/node/models/load-status/clear") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let name = body["model"] as? String ?? ""
            let mm = nodeService.modelManager
            // Only a failed entry is clearable — the tracker's other states are
            // derived from what is actually loaded, so "clearing" a loaded
            // model would just report a lie until the next poll rebuilt it.
            guard !name.isEmpty, mm.loadError != nil, mm.loadingModelName == name else {
                return try Self.error("not found", status: .notFound)
            }
            await MainActor.run { mm.clearLoadError() }
            return try Self.json(["status": "cleared", "model": name])
        }

        // GET /v1/node/models/{model_name}/config — the config behind an edit
        // form. API keys are never returned, only a last-four hint.
        router.get("/v1/node/models/:model_name/config") { _, context -> Response in
            let name = context.parameters.get("model_name").map { String($0) } ?? ""
            let mm = nodeService.modelManager
            guard let model = mm.loadedModels.first(where: { $0.name == name || $0.filename == name })
            else {
                return try Self.error("model not found", status: .notFound)
            }

            var result: [String: Any] = [
                "name": model.name,
                "backend": model.backend,
                "ctx_len": model.contextLength,
            ]
            if let config = mm.savedAPIConfigs().first(where: { $0.name == model.name }) {
                result["backend"] = "openai"
                result["api_base"] = config.apiBase
                result["api_model"] = config.apiModel
                result["ctx_len"] = config.ctxLen
                result["api_key_hint"] = config.apiKey.count > 4
                    ? "...\(String(config.apiKey.suffix(4)))"
                    : ""
            }
            return try Self.json(result)
        }

        // POST /v1/node/models/update — merge overrides into a saved config and
        // reload. Only saved (openai-backend) configs are updatable; a local
        // GGUF/MLX file has no config to merge, which is why Python looks the
        // model up in _saved_configs and errors when it isn't there.
        router.post("/v1/node/models/update") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let name = body["model"] as? String ?? ""
            guard !name.isEmpty else { return try Self.error("model name required") }

            let mm = nodeService.modelManager
            guard let existing = mm.savedAPIConfigs().first(where: { $0.name == name }) else {
                return try Self.error("No config for '\(name)'", status: .notFound)
            }

            // Omitted fields keep their current values — an edit form that
            // sends only the changed field must not blank the rest.
            let apiBase = (body["api_base"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? existing.apiBase
            let apiModel = (body["api_model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? existing.apiModel
            let apiKey = (body["api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? existing.apiKey
            let ctxLen = (body["ctx_len"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? existing.ctxLen

            if let loaded = mm.loadedModels.first(where: { $0.name == name }) {
                await mm.unloadModel(loaded)
            }
            do {
                try await mm.loadAPIModel(
                    name: name, apiBase: apiBase, apiKey: apiKey,
                    apiModel: apiModel, ctxLen: ctxLen
                )
                return try Self.json(["status": "updated", "model": name])
            } catch {
                return try Self.error(error.localizedDescription)
            }
        }

        // POST /v1/node/models/reload — re-load a saved config that was unloaded.
        router.post("/v1/node/models/reload") { request, _ -> Response in
            let body = try await Self.parseBody(request)
            let name = body["model"] as? String ?? ""
            guard !name.isEmpty else { return try Self.error("model name required") }

            let mm = nodeService.modelManager
            if let config = mm.savedAPIConfigs().first(where: { $0.name == name }) {
                do {
                    try await mm.loadAPIModel(
                        name: config.name, apiBase: config.apiBase, apiKey: config.apiKey,
                        apiModel: config.apiModel, ctxLen: config.ctxLen
                    )
                    return try Self.json(["status": "loaded", "model": name, "backend": "openai"])
                } catch {
                    return try Self.error(error.localizedDescription)
                }
            }

            // Local files have no saved config, but "reload this model" is still
            // a meaningful request for one — Python reaches the same outcome via
            // a saved config carrying model_path. Falling back to the on-disk
            // file keeps the endpoint useful on a device, where local files are
            // the common case rather than the exception.
            guard let file = mm.localFiles.first(where: { $0.filename == name || $0.path == name })
            else {
                return try Self.error("No saved config for '\(name)'", status: .notFound)
            }
            Task { try? await mm.loadModel(file: file) }
            let detected = ModelFormat.detect(path: file.path) == .mlx ? "mlx" : "llama.cpp"
            return try Self.json(["status": "loading", "model": file.filename, "backend": detected])
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

        // GET /v1/node/credits/networks — per-network authoritative balances.
        //
        // These come from the tracker (the source of truth) and are cached on
        // device by `reconcileTrackerCredits`, so this reads the cache rather
        // than re-querying — a dashboard poll must not fan out to the tracker.
        router.get("/v1/node/credits/networks") { _, _ -> Response in
            let balances = nodeService.stats.networkBalances
            return try Self.json([
                "networks": balances.map { b in
                    [
                        "network_id": b.networkId,
                        "label": b.networkId.isEmpty ? "default" : b.networkId,
                        "balance": b.balance,
                        "earned": b.earned,
                        "spent": b.spent,
                        "tracked": true,
                    ] as [String: Any]
                },
                "aggregate": [
                    "balance": balances.reduce(0) { $0 + $1.balance },
                    "earned": balances.reduce(0) { $0 + $1.earned },
                    "spent": balances.reduce(0) { $0 + $1.spent },
                ] as [String: Any],
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
