import Foundation

/// OpenAI-compatible API routes: /v1/chat/completions, /v1/models, /v1/models/capabilities.
///
/// Mirrors the Python reference at src/mycellm/api/openai.py — supports tool/function
/// calling, reasoning ("thinking") suppression with side-channel reasoning_content,
/// streaming SSE with typed deltas, and per-model capability advertisement.
enum OpenAIRoutes {

    // MARK: - /v1/models (basic listing)

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

    // MARK: - /v1/models/{model_id} (retrieve one)

    /// Retrieve a single model. Returns nil when the id is unknown, which the
    /// router turns into a 404 — OpenAI clients treat a 200-with-error as a
    /// successful retrieval and carry on with a model that isn't there.
    ///
    /// `auto` is virtual: Python answers for it whenever anything is reachable,
    /// because it is the name a client sends to mean "you pick". An iOS node
    /// with no model loaded cannot serve it, so it is reported only when a
    /// model is actually loaded.
    static func retrieveModel(id: String, manager: ModelManager) -> [String: Any]? {
        let now = Int(Date().timeIntervalSince1970)

        if id == "auto" {
            guard !manager.loadedModels.isEmpty else { return nil }
            return ["id": "auto", "object": "model", "created": now, "owned_by": "mycellm"]
        }

        guard let model = manager.loadedModels.first(where: { $0.name == id || $0.filename == id })
        else { return nil }

        return [
            "id": model.name,
            "object": "model",
            "created": Int(model.loadedAt.timeIntervalSince1970),
            "owned_by": "local",
        ]
    }

    // MARK: - /v1/models/capabilities (rich per-model metadata)

    /// Rich per-model metadata. New in v0.3.0: surfaces `supports_thinking`
    /// so clients can gate reasoning-related UI affordances on whether the
    /// network actually has a thinking-capable model available.
    static func listCapabilities(manager: ModelManager) -> [String: Any] {
        let models = manager.loadedModels.map { model -> [String: Any] in
            [
                "id": model.name,
                "source": "local",
                "status": "loaded",
                "param_count_b": model.paramCountB,
                "quantization": model.quant,
                "context_length": model.contextLength,
                "backend": model.backend,
                "features": ["streaming"],
                "supports_grammar": model.backend == "llama.cpp",
                "supports_thinking": ReasoningDialects.supportsThinking(model.name),
                // Advertised so a client can route an embeddings request to a
                // node that can serve it instead of discovering it can't by
                // getting a 400 back — which is exactly why this has to honour
                // `embeddingsEnabled` and not just "is it an embedding model on
                // the right backend". Reporting true while the execution path
                // is gated off would send every embeddings client here to fail.
                "supports_embeddings": LlamaCppBackend.embeddingsEnabled
                    && model.backend == "llama.cpp"
                    && EmbeddingModels.isEmbeddingModel(model.name),
                "tags": EmbeddingModels.tags(for: model.name),
            ]
        }
        return ["models": models]
    }

    // MARK: - /v1/embeddings

    /// POST /v1/embeddings request body.
    struct EmbeddingsRequest: Codable, Sendable {
        var model: String = ""
        var input: EmbeddingInput? = nil

        init(model: String = "", input: EmbeddingInput? = nil) {
            self.model = model
            self.input = input
        }

        /// ⚠️ HAND-WRITTEN BECAUSE SYNTHESISED `Codable` IGNORES DEFAULT VALUES.
        /// `{"input": "hello"}` is a valid request — Python's `model` defaults
        /// to `""` — but the synthesised decoder treats a missing key for a
        /// non-optional `String` as `keyNotFound` and throws; the property's
        /// default is never consulted. The whole body then failed to decode and
        /// the route answered with the token-array error, which is both wrong
        /// and impossible for a caller to act on. Every field is optional on
        /// the wire, exactly as it is in Python's pydantic model.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            self.input = try c.decodeIfPresent(EmbeddingInput.self, forKey: .input)
        }
    }

    /// The `input` field: a string, or a list of strings.
    ///
    /// ⚠️ UNPARSEABLE INPUT DECODES TO `.unsupported` RATHER THAN THROWING.
    /// OpenAI also allows token arrays (`[Int]`/`[[Int]]`), which local
    /// backends can't take because they tokenize text themselves. If this
    /// rejected them at the decoder, the whole request body would fail to
    /// decode and the client would get a generic parse error — where Python
    /// answers with a specific `invalid_input` explaining to send strings.
    /// Carrying the failure as a case preserves that message.
    enum EmbeddingInput: Codable, Sendable {
        case text(String)
        case texts([String])
        case unsupported

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .text(s)
            } else if let a = try? c.decode([String].self) {
                self = .texts(a)
            } else {
                self = .unsupported
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .texts(let a): try c.encode(a)
            case .unsupported: try c.encodeNil()
            }
        }

        /// The texts to embed, or nil when the input form isn't supported.
        var texts: [String]? {
            switch self {
            case .text(let s): [s]
            case .texts(let a): a
            case .unsupported: nil
            }
        }
    }

    /// OpenAI error envelope. Python returns this shape for every embeddings
    /// failure and clients branch on `error.code`, so a plain `{"error": "..."}`
    /// — what the rest of this node's routes return — would not be readable by
    /// an OpenAI SDK.
    static func errorBody(_ message: String, type: String, code: String) -> [String: Any] {
        ["error": ["message": message, "type": type, "code": code]]
    }

    /// Build the success body for an embeddings response.
    static func embeddingsBody(_ result: EmbeddingResult, model: String) -> [String: Any] {
        [
            "object": "list",
            "data": result.embeddings.enumerated().map { i, vector in
                ["object": "embedding", "index": i, "embedding": vector] as [String: Any]
            },
            "model": model,
            "usage": [
                "prompt_tokens": result.totalTokens,
                "total_tokens": result.totalTokens,
            ] as [String: Any],
        ]
    }

    // MARK: - Request / Response shapes

    /// Tool definition (OpenAI-style function tool). Codable via decode-only;
    /// the underlying shape is opaque to mycellm — we just forward it.
    struct Tool: Codable, Sendable {
        let type: String?
        let function: [String: AnyCodable]?
    }

    /// `tool_choice` accepts a string ("auto" | "none" | "required") or a
    /// dict naming the specific tool. We model it loosely.
    enum ToolChoice: Codable, Sendable {
        case string(String)
        case dict([String: AnyCodable])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else {
                self = .dict(try c.decode([String: AnyCodable].self))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .dict(let d): try c.encode(d)
            }
        }
    }

    /// Reasoning ("thinking") control block. OpenAI-o-series style.
    struct ReasoningOptions: Codable, Sendable {
        /// When true, strip thinking from response. When false, surface it.
        /// nil means "use server default" (Preferences.hideReasoningByDefault).
        let exclude: Bool?
        /// OpenAI o-series effort hint. Passed through to relay backends.
        let effort: String?
    }

    /// `mycellm` quality-routing block on chat-completions requests.
    struct MycellmRouting: Codable, Sendable {
        let min_tier: String?
        let min_params: Double?
        let min_context: Int?
        let required_tags: [String]?
        let max_cost: Double?
        let routing: String?
        let fallback: String?
        let trust: String?
    }

    /// POST /v1/chat/completions request body. Full v0.4.0 surface
    /// (incl. multimodal `content` arrays).
    struct ChatCompletionRequest: Codable, Sendable {
        let model: String
        let messages: [Message]
        var temperature: Double? = 0.7
        var max_tokens: Int? = 2048
        /// OpenAI renamed max_tokens → max_completion_tokens for chat
        /// completions; newer SDK clients send the new name. Accept it as an
        /// alias (max_tokens wins if both are present) via `resolvedMaxTokens`.
        var max_completion_tokens: Int? = nil
        var stream: Bool? = false
        var top_p: Double? = 1.0
        var stop: StringOrArray? = nil
        var frequency_penalty: Double? = 0
        var presence_penalty: Double? = 0
        var seed: Int? = nil
        var response_format: [String: AnyCodable]? = nil
        var grammar: String? = nil
        var tools: [Tool]? = nil
        var tool_choice: ToolChoice? = nil
        var reasoning: ReasoningOptions? = nil
        var mycellm: MycellmRouting? = nil

        /// Generation cap: max_tokens, else max_completion_tokens, else 2048.
        var resolvedMaxTokens: Int { max_tokens ?? max_completion_tokens ?? 2048 }

        /// Chat message — supports assistant tool_calls, tool role, and
        /// multimodal (image) content.
        struct Message: Codable, Sendable {
            let role: String
            /// Plain string for text, or an array of content parts for images.
            let content: MessageContent?
            let tool_calls: [AnyCodable]?
            let tool_call_id: String?
            let name: String?

            init(role: String, content: MessageContent?, tool_calls: [AnyCodable]? = nil, tool_call_id: String? = nil, name: String? = nil) {
                self.role = role
                self.content = content
                self.tool_calls = tool_calls
                self.tool_call_id = tool_call_id
                self.name = name
            }

            /// Concatenated text of the content (image parts dropped).
            var textContent: String { content?.textValue ?? "" }
            /// Decoded inline image bytes (data: URIs), in document order.
            var imageData: [Data] { content?.imageData ?? [] }
            /// Project to the backend's multimodal message shape.
            func asMultimodal() -> MultimodalMessage {
                MultimodalMessage(role: role, text: textContent, images: imageData)
            }
        }
    }

    /// Message content: a plain string, or an array of multimodal parts —
    /// `[{type:"text",text}, {type:"image_url",image_url:{url}}]`. Mirrors the
    /// Python `ChatMessage.content: str | list[dict]` widening.
    enum MessageContent: Codable, Sendable {
        case text(String)
        case parts([ContentPart])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .text(s)
            } else {
                self = .parts(try c.decode([ContentPart].self))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .parts(let p): try c.encode(p)
            }
        }

        /// Text of all text parts concatenated (image parts dropped).
        var textValue: String {
            switch self {
            case .text(let s): return s
            case .parts(let ps): return ps.compactMap { $0.type == "text" ? $0.text : nil }.joined()
            }
        }
        /// Decoded bytes of inline image parts (data: URIs only; http/file URLs
        /// are not fetched server-side).
        var imageData: [Data] {
            guard case .parts(let ps) = self else { return [] }
            return ps.compactMap { part in
                guard part.type == "image_url", let url = part.image_url?.url else { return nil }
                return MultimodalMessage.decodeDataURI(url)
            }
        }
    }

    /// One OpenAI content part: `text` set for type "text"; `image_url` for
    /// type "image_url".
    struct ContentPart: Codable, Sendable {
        let type: String
        let text: String?
        let image_url: ImageURL?
        struct ImageURL: Codable, Sendable { let url: String }
    }

    /// SSE/JSON `stop` field can be a single string or array of strings.
    enum StringOrArray: Codable, Sendable {
        case string(String)
        case array([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else {
                self = .array(try c.decode([String].self))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            }
        }
        var asArray: [String] {
            switch self {
            case .string(let s): return [s]
            case .array(let a): return a
            }
        }
    }

    // MARK: - Helpers

    /// Decide whether to suppress reasoning for this request. Explicit
    /// `body.reasoning.exclude` wins; otherwise fall back to the
    /// `hideReasoningByDefault` preference. iOS app default is true so
    /// chat UI looks clean for end users.
    ///
    /// Reads UserDefaults directly (instead of going through
    /// @MainActor Preferences.shared) so this stays usable from any
    /// task context — HTTP request handlers run off-main.
    static func resolveReasoningExclude(_ reasoning: ReasoningOptions?) -> Bool {
        if let exclude = reasoning?.exclude {
            return exclude
        }
        // Mirrors Preferences.hideReasoningByDefault — default true.
        return (UserDefaults.standard.object(forKey: "hide_reasoning_by_default") as? Bool) ?? true
    }
}

/// Loose JSON value used inside Codable containers when the schema is opaque
/// (e.g. arbitrary nested function-tool definitions). Round-trips dictionaries,
/// arrays, strings, numbers, booleans, and null.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            self.value = b
        } else if let i = try? c.decode(Int.self) {
            self.value = i
        } else if let d = try? c.decode(Double.self) {
            self.value = d
        } else if let s = try? c.decode(String.self) {
            self.value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map(\.value)
        } else if let obj = try? c.decode([String: AnyCodable].self) {
            self.value = obj.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyCodable: unsupported value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map { AnyCodable($0) })
        case let obj as [String: Any]: try c.encode(obj.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: c.codingPath, debugDescription: "AnyCodable: unencodable value"))
        }
    }
}
