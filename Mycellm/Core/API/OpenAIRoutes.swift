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
            ]
        }
        return ["models": models]
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

    /// POST /v1/chat/completions request body. Full v0.3.0 surface.
    struct ChatCompletionRequest: Codable, Sendable {
        let model: String
        let messages: [Message]
        var temperature: Double? = 0.7
        var max_tokens: Int? = 2048
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

        /// Chat message — supports assistant tool_calls and tool role.
        struct Message: Codable, Sendable {
            let role: String
            let content: String?
            let tool_calls: [AnyCodable]?
            let tool_call_id: String?
            let name: String?

            init(role: String, content: String?, tool_calls: [AnyCodable]? = nil, tool_call_id: String? = nil, name: String? = nil) {
                self.role = role
                self.content = content
                self.tool_calls = tool_calls
                self.tool_call_id = tool_call_id
                self.name = name
            }
        }
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
    static func resolveReasoningExclude(_ reasoning: ReasoningOptions?) -> Bool {
        if let exclude = reasoning?.exclude {
            return exclude
        }
        return Preferences.shared.hideReasoningByDefault
    }
}

/// Loose JSON value used inside Codable containers when the schema is opaque
/// (e.g. arbitrary nested function-tool definitions). Round-trips dictionaries,
/// arrays, strings, numbers, booleans, and null.
struct AnyCodable: Codable, Sendable, @unchecked Sendable {
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
