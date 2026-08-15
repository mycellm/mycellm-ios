import Foundation

/// Model format detected from file extension or header bytes.
enum ModelFormat: String, Sendable {
    case gguf       // llama.cpp — .gguf files
    case mlx        // MLX — safetensors directories with config.json
    case unknown

    static func detect(path: String) -> ModelFormat {
        // Single file with .gguf extension
        if path.hasSuffix(".gguf") {
            return .gguf
        }

        // Directory containing config.json + *.safetensors = MLX model
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            let hasConfig = fm.fileExists(atPath: (path as NSString).appendingPathComponent("config.json"))
            let hasSafetensors = (try? fm.contentsOfDirectory(atPath: path))?
                .contains(where: { $0.hasSuffix(".safetensors") }) ?? false
            if hasConfig && hasSafetensors {
                return .mlx
            }
        }

        return .unknown
    }

    /// True if an MLX model directory is a vision-language model — its
    /// config.json declares a vision tower / image-token. Mirrors the Python
    /// `is_mlx_vlm_model_path`. `ModelFormat.detect` still returns `.mlx` for
    /// these (so InferenceEngine picks MLXBackend); MLXBackend uses this to
    /// choose the VLM load + prompt path internally.
    static func isVisionModel(path: String) -> Bool {
        let cfg = (path as NSString).appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: cfg),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        for key in ["vision_config", "image_token_index", "image_token_id"] {
            if obj[key] != nil { return true }
        }
        // model_type fallback for families that don't expose either key.
        let visionTypes: Set<String> = [
            "llava", "llava_next", "qwen2_vl", "qwen2_5_vl", "idefics2",
            "idefics3", "paligemma", "pixtral", "mllama", "phi3_v",
            "multi_modality", "internvl_chat", "smolvlm", "gemma3", "gemma3n",
        ]
        if let mt = (obj["model_type"] as? String)?.lowercased(), visionTypes.contains(mt) {
            return true
        }
        return false
    }
}

/// A chat message that may carry images alongside text — the OpenAI multimodal
/// shape. Text-only backends flatten it to `[role, content]` via
/// ``asTextMessage`` (images dropped); the MLX VLM path consumes ``images``.
///
/// This is the additive counterpart to the `[[String: String]]` messages the
/// existing protocol methods take — adding it leaves the text path untouched.
struct MultimodalMessage: Sendable {
    let role: String
    let text: String
    /// Encoded image bytes (PNG/JPEG), in document order. Empty for text turns.
    let images: [Data]

    init(role: String, text: String, images: [Data] = []) {
        self.role = role
        self.text = text
        self.images = images
    }

    /// Collapse to the legacy string-message shape (drops images).
    var asTextMessage: [String: String] { ["role": role, "content": text] }

    /// Decode a `data:[<mime>];base64,<data>` URI to raw bytes. Returns nil for
    /// non-data URIs (http/file URLs are fetched elsewhere) or malformed input.
    static func decodeDataURI(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url[url.startIndex..<comma].contains(";base64")
        else { return nil }
        let b64 = String(url[url.index(after: comma)...])
        return Data(base64Encoded: b64)
    }
}

extension Array where Element == MultimodalMessage {
    /// True if any message carries at least one image.
    var hasImages: Bool { contains { !$0.images.isEmpty } }
    /// Flatten to legacy string messages (images dropped).
    var asTextMessages: [[String: String]] { map(\.asTextMessage) }
}

/// Inference result from a non-streaming completion.
struct InferenceResult: Sendable {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
    /// Tool calls parsed from the model's output, if any. Empty when no
    /// tools were requested or the model didn't invoke any.
    let toolCalls: [ToolCallParser.ParsedToolCall]

    init(text: String, promptTokens: Int, completionTokens: Int,
         toolCalls: [ToolCallParser.ParsedToolCall] = []) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.toolCalls = toolCalls
    }
}

/// Result of an embeddings request — one vector per input, in input order.
struct EmbeddingResult: Sendable {
    let embeddings: [[Double]]
    /// Prompt tokens consumed across every input. `/v1/embeddings` reports this
    /// as both `prompt_tokens` and `total_tokens`, as Python does — an
    /// embedding request generates nothing, so the two are equal by definition.
    let totalTokens: Int
}

/// Protocol for pluggable inference backends.
/// Each backend handles one model format and provides the same interface.
protocol InferenceBackend: Actor {
    /// Human-readable name (e.g. "llama.cpp", "MLX")
    var backendName: String { get }

    /// Currently loaded model name, if any.
    var loadedModel: String? { get }

    /// Tokens per second from the last inference.
    var tokensPerSecond: Double { get }

    /// Load a model from the given path with the requested context length.
    /// Callers (InferenceEngine via ModelManager) source ctxLen from
    /// Preferences.defaultCtxLen unless an explicit override is provided
    /// via the /v1/node/models/load HTTP endpoint.
    func loadModel(path: String, name: String, ctxLen: Int) async throws

    /// Unload the current model and free resources.
    func unloadModel()

    /// Non-streaming completion. Optional tools array is injected into
    /// the system prompt; the backend parses tool calls out of the model
    /// output and surfaces them on InferenceResult.toolCalls.
    func complete(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) async throws -> InferenceResult

    /// Streaming completion — yields text chunks. Tools are injected into
    /// the system prompt but tool-call parsing is non-streaming-only for
    /// v0.3.0 (callers requesting tools should set stream=false).
    func stream(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) -> AsyncThrowingStream<String, Error>

    /// Embed one or more texts. Backends that cannot embed inherit the default
    /// below, which throws `MycellmError.embeddingsNotSupported` — the same
    /// distinction Python draws between "no embedding model loaded" and "this
    /// backend has no embedding path at all".
    func embed(_ texts: [String]) async throws -> EmbeddingResult

    /// True when `embed` can succeed with the currently loaded model. Reported
    /// on `/v1/models/capabilities` so a client can pick an embedding-capable
    /// node before sending a request that would only fail.
    var supportsEmbeddings: Bool { get }

    /// Reset context (clear KV cache) without unloading the model.
    func resetContext() throws

    /// Release all resources.
    func cleanup()

    /// Multimodal (vision) completion. Default implementation flattens to text
    /// and calls ``complete(messages:temperature:maxTokens:tools:)`` — so
    /// text-only backends need no changes. The MLX backend overrides this to
    /// feed images to a VLM model.
    func complete(
        multimodal messages: [MultimodalMessage],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) async throws -> InferenceResult

    /// Streaming multimodal completion. Default flattens to text (see above).
    func stream(
        multimodal messages: [MultimodalMessage],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) -> AsyncThrowingStream<String, Error>
}

// Default multimodal implementations: drop images and use the text path. This
// makes the new requirements opt-in — LlamaCppBackend and the MLX text path
// inherit these unchanged; only MLXBackend overrides them for real VLM input.
extension InferenceBackend {
    /// Default: no embedding path. Overridden by LlamaCppBackend.
    var supportsEmbeddings: Bool { false }

    func embed(_ texts: [String]) async throws -> EmbeddingResult {
        throw MycellmError.embeddingsNotSupported(
            "the \(backendName) backend has no embedding path"
        )
    }

    func complete(
        multimodal messages: [MultimodalMessage],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) async throws -> InferenceResult {
        try await complete(
            messages: messages.asTextMessages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools
        )
    }

    func stream(
        multimodal messages: [MultimodalMessage],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) -> AsyncThrowingStream<String, Error> {
        stream(
            messages: messages.asTextMessages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools
        )
    }
}
