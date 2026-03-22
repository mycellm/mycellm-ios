import Foundation

/// Actor wrapping llama.cpp for Metal-accelerated inference.
/// Phase 2 will integrate the actual llama.cpp SPM package.
actor InferenceEngine {
    enum State: Sendable {
        case idle
        case loading(String)
        case ready(String)
        case inferring(String)
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var currentModel: String?
    private(set) var tokensPerSecond: Double = 0.0

    /// Load a GGUF model from disk.
    func loadModel(path: String, name: String) async throws {
        let fileSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 ?? 0
        let fit = HardwareInfo.ramFit(modelSizeBytes: fileSize)
        guard fit != .tooLarge else {
            throw MycellmError.modelTooLarge(needed: fileSize, available: HardwareInfo.availableMemory)
        }

        state = .loading(name)
        // TODO: Phase 2 — llama_model_load_from_file(), llama_context_init()
        currentModel = name
        state = .ready(name)
    }

    /// Unload the current model.
    func unloadModel() {
        // TODO: Phase 2 — llama_free(), llama_model_free()
        currentModel = nil
        state = .idle
    }

    /// Run inference (non-streaming). Returns generated text.
    func complete(messages: [[String: String]], temperature: Double = 0.7, maxTokens: Int = 2048) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        guard let model = currentModel else {
            throw MycellmError.modelNotLoaded("No model loaded")
        }
        state = .inferring(model)
        defer { state = .ready(model) }

        // TODO: Phase 2 — llama_decode(), token sampling loop
        throw MycellmError.inferenceError("Inference engine not yet implemented (Phase 2)")
    }

    /// Run inference with streaming. Yields tokens as they're generated.
    func stream(messages: [[String: String]], temperature: Double = 0.7, maxTokens: Int = 2048) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // TODO: Phase 2 — streaming token generation
            continuation.finish(throwing: MycellmError.inferenceError("Streaming not yet implemented (Phase 2)"))
        }
    }
}
