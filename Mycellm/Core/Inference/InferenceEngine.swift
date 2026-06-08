import Foundation

/// Inference engine router — delegates to the right backend based on model format.
///
/// Callers (ChatView, NodeService, HTTPServer) use the same API regardless of
/// whether the model is GGUF (llama.cpp) or MLX (safetensors). The backend is
/// selected automatically when a model is loaded.
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

    /// The active backend — nil until a model is loaded.
    private var backend: (any InferenceBackend)?

    /// Name of the active backend ("llama.cpp", "MLX", etc.)
    var backendName: String {
        get async { await backend?.backendName ?? "none" }
    }

    init() {}

    func cleanup() {
        Task {
            await backend?.cleanup()
        }
        backend = nil
    }

    // MARK: - Load / Unload

    func loadModel(path: String, name: String, ctxLen: Int) async throws {
        let format = ModelFormat.detect(path: path)

        // Select backend based on model format
        let newBackend: any InferenceBackend
        switch format {
        case .gguf:
            newBackend = LlamaCppBackend()
        case .mlx:
            newBackend = MLXBackend()
        case .unknown:
            throw MycellmError.inferenceError("Unknown model format at \(path). Expected .gguf file or MLX directory with config.json + safetensors.")
        }

        // Clean up previous backend
        await backend?.cleanup()

        state = .loading(name)
        do {
            try await newBackend.loadModel(path: path, name: name, ctxLen: ctxLen)
            backend = newBackend
            currentModel = name
            tokensPerSecond = 0
            state = .ready(name)
        } catch {
            state = .error("Failed to load \(name)")
            throw error
        }
    }

    func unloadModel() {
        Task {
            await backend?.unloadModel()
        }
        backend = nil
        currentModel = nil
        state = .idle
        tokensPerSecond = 0
    }

    // MARK: - Inference

    /// Non-streaming completion. Returns text + token counts + any
    /// tool_calls parsed by the backend from the model's raw output.
    func complete(
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        tools: [OpenAIRoutes.Tool] = []
    ) async throws -> InferenceResult {
        guard let backend else {
            throw MycellmError.modelNotLoaded("No model loaded")
        }

        state = .inferring(currentModel ?? "")
        defer { state = .ready(currentModel ?? "") }

        let result = try await backend.complete(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools
        )
        tokensPerSecond = await backend.tokensPerSecond
        return result
    }

    func stream(
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        tools: [OpenAIRoutes.Tool] = []
    ) -> AsyncThrowingStream<String, Error> {
        guard let backend else {
            return AsyncThrowingStream { $0.finish(throwing: MycellmError.modelNotLoaded("No model loaded")) }
        }

        state = .inferring(currentModel ?? "")

        let capturedBackend = backend
        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                do {
                    let inner = await capturedBackend.stream(
                        messages: messages,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        tools: tools
                    )
                    for try await chunk in inner {
                        continuation.yield(chunk)
                    }
                    if let self {
                        await self.updateAfterStream()
                    }
                    continuation.finish()
                } catch {
                    if let self {
                        await self.updateAfterStream()
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Multimodal inference (vision)

    /// Non-streaming completion with image-capable messages. Delegates to the
    /// backend's multimodal path — the MLX backend feeds images to a VLM model;
    /// text backends flatten to text (default protocol impl). Mirrors
    /// ``complete(messages:temperature:maxTokens:tools:)``.
    func complete(
        multimodal messages: [MultimodalMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        tools: [OpenAIRoutes.Tool] = []
    ) async throws -> InferenceResult {
        guard let backend else {
            throw MycellmError.modelNotLoaded("No model loaded")
        }
        state = .inferring(currentModel ?? "")
        defer { state = .ready(currentModel ?? "") }

        let result = try await backend.complete(
            multimodal: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools
        )
        tokensPerSecond = await backend.tokensPerSecond
        return result
    }

    func stream(
        multimodal messages: [MultimodalMessage],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        tools: [OpenAIRoutes.Tool] = []
    ) -> AsyncThrowingStream<String, Error> {
        guard let backend else {
            return AsyncThrowingStream { $0.finish(throwing: MycellmError.modelNotLoaded("No model loaded")) }
        }
        state = .inferring(currentModel ?? "")

        let capturedBackend = backend
        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                do {
                    let inner = await capturedBackend.stream(
                        multimodal: messages,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        tools: tools
                    )
                    for try await chunk in inner {
                        continuation.yield(chunk)
                    }
                    if let self {
                        await self.updateAfterStream()
                    }
                    continuation.finish()
                } catch {
                    if let self {
                        await self.updateAfterStream()
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func updateAfterStream() async {
        if let backend {
            tokensPerSecond = await backend.tokensPerSecond
        }
        state = .ready(currentModel ?? "")
    }

    // MARK: - Context Reset

    func resetContext() throws {
        guard let backend else {
            throw MycellmError.modelNotLoaded("No model loaded")
        }
        // Synchronous call — backend implementations handle this
        // within their own actor context via a detached task
        Task {
            try await backend.resetContext()
        }
    }
}
