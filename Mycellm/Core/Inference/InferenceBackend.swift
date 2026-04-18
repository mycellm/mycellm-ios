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

    /// Load a model from the given path.
    func loadModel(path: String, name: String) async throws

    /// Unload the current model and free resources.
    func unloadModel()

    /// Non-streaming completion.
    func complete(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) async throws -> InferenceResult

    /// Streaming completion — yields text chunks.
    func stream(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error>

    /// Reset context (clear KV cache) without unloading the model.
    func resetContext() throws

    /// Release all resources.
    func cleanup()
}
