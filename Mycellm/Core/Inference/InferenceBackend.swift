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

    /// Reset context (clear KV cache) without unloading the model.
    func resetContext() throws

    /// Release all resources.
    func cleanup()
}
