import Foundation
import LlamaSwift

/// Actor wrapping llama.cpp for Metal-accelerated GGUF inference on iOS.
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

    nonisolated(unsafe) private var model: OpaquePointer?
    nonisolated(unsafe) private var ctx: OpaquePointer?

    init() {
        llama_backend_init()
    }

    deinit {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        llama_backend_free()
    }

    // MARK: - Load / Unload

    func loadModel(path: String, name: String) async throws {
        // Verify file exists and has reasonable size
        guard FileManager.default.fileExists(atPath: path) else {
            throw MycellmError.inferenceError("File not found: \(path)")
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        guard fileSize > 1024 * 1024 else {
            throw MycellmError.inferenceError("File too small to be a valid GGUF model (\(fileSize) bytes)")
        }

        // Verify GGUF magic number (first 4 bytes = "GGUF" = 0x46475547)
        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw MycellmError.inferenceError("Cannot read file")
        }
        let magic = fh.readData(ofLength: 4)
        fh.closeFile()
        guard magic.count == 4 && magic == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw MycellmError.inferenceError("Not a valid GGUF file — delete and re-download")
        }

        let fit = HardwareInfo.ramFit(modelSizeBytes: fileSize)
        guard fit != .tooLarge else {
            throw MycellmError.modelTooLarge(needed: fileSize, available: HardwareInfo.availableMemory)
        }

        // Free existing
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }

        state = .loading(name)

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99  // Full Metal GPU offload

        guard let m = llama_model_load_from_file(path, modelParams) else {
            state = .error("Failed to load model")
            throw MycellmError.inferenceError("llama_model_load_from_file failed — file may be corrupt")
        }
        model = m

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = 512
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        guard let c = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            model = nil
            state = .error("Failed to create context")
            throw MycellmError.inferenceError("llama_init_from_model failed")
        }
        ctx = c
        currentModel = name
        state = .ready(name)
    }

    func unloadModel() {
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        currentModel = nil
        state = .idle
        tokensPerSecond = 0
    }

    // MARK: - Inference

    func complete(
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        guard let model, let ctx else {
            throw MycellmError.modelNotLoaded("No model loaded")
        }

        state = .inferring(currentModel ?? "")
        defer { state = .ready(currentModel ?? "") }

        let prompt = applyChatTemplate(messages: messages, model: model)
        var promptTokens = tokenize(text: prompt, model: model)

        // Decode prompt
        let promptBatch = llama_batch_get_one(&promptTokens, Int32(promptTokens.count))
        guard llama_decode(ctx, promptBatch) == 0 else {
            throw MycellmError.inferenceError("Prompt decode failed")
        }

        let sampler = buildSampler(temperature: Float(temperature))
        defer { llama_sampler_free(sampler) }

        let vocab = llama_model_get_vocab(model)
        var outputTokens: [llama_token] = []
        let startTime = Date()

        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            outputTokens.append(token)

            var tok = token
            let nextBatch = llama_batch_get_one(&tok, 1)
            guard llama_decode(ctx, nextBatch) == 0 else { break }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        tokensPerSecond = elapsed > 0 ? Double(outputTokens.count) / elapsed : 0

        let text = detokenize(tokens: outputTokens, model: model)
        return (text, promptTokens.count, outputTokens.count)
    }

    func stream(
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        Task {
            do {
                try await self.streamImpl(messages: messages, temperature: temperature, maxTokens: maxTokens, continuation: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    private func streamImpl(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let model, let ctx else {
            throw MycellmError.modelNotLoaded("No model loaded")
        }

        state = .inferring(currentModel ?? "")
        defer { state = .ready(currentModel ?? "") }

        let prompt = applyChatTemplate(messages: messages, model: model)
        var promptTokens = tokenize(text: prompt, model: model)

        let promptBatch = llama_batch_get_one(&promptTokens, Int32(promptTokens.count))
        guard llama_decode(ctx, promptBatch) == 0 else {
            throw MycellmError.inferenceError("Prompt decode failed")
        }

        let sampler = buildSampler(temperature: Float(temperature))
        defer { llama_sampler_free(sampler) }

        let vocab = llama_model_get_vocab(model)
        let startTime = Date()
        var count = 0

        for _ in 0..<maxTokens {
            if Task.isCancelled { break }

            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            let piece = detokenize(tokens: [token], model: model)
            continuation.yield(piece)
            count += 1

            var tok = token
            let nextBatch = llama_batch_get_one(&tok, 1)
            guard llama_decode(ctx, nextBatch) == 0 else { break }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        tokensPerSecond = elapsed > 0 ? Double(count) / elapsed : 0
        continuation.finish()
    }

    // MARK: - Helpers

    private func tokenize(text: String, model: OpaquePointer) -> [llama_token] {
        let vocab = llama_model_get_vocab(model)
        let cStr = Array(text.utf8CString)
        let nMax = Int32(cStr.count) + 2
        var tokens = [llama_token](repeating: 0, count: Int(nMax))
        let n = cStr.withUnsafeBufferPointer { buf in
            llama_tokenize(vocab, buf.baseAddress, Int32(cStr.count - 1), &tokens, nMax, true, true)
        }
        guard n > 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    private func detokenize(tokens: [llama_token], model: OpaquePointer) -> String {
        let vocab = llama_model_get_vocab(model)
        var result = ""
        for token in tokens {
            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(vocab, token, &buf, 256, 0, true)
            if len > 0 {
                buf[Int(len)] = 0
                result += String(cString: buf)
            }
        }
        return result
    }

    private func buildSampler(temperature: Float) -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(params)!
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        return chain
    }

    private func applyChatTemplate(messages: [[String: String]], model: OpaquePointer) -> String {
        var chatMsgs = messages.map { msg -> llama_chat_message in
            llama_chat_message(
                role: strdup(msg["role"] ?? "user"),
                content: strdup(msg["content"] ?? "")
            )
        }
        defer {
            for m in chatMsgs {
                free(UnsafeMutablePointer(mutating: m.role))
                free(UnsafeMutablePointer(mutating: m.content))
            }
        }

        var buf = [CChar](repeating: 0, count: 32768)
        let tmpl = llama_model_chat_template(model, nil)
        let n = llama_chat_apply_template(tmpl, &chatMsgs, chatMsgs.count, true, &buf, Int32(buf.count))

        if n > 0 && n < buf.count {
            buf[Int(n)] = 0
            return String(cString: buf)
        }

        // Fallback ChatML
        var prompt = ""
        for msg in messages {
            prompt += "<|im_start|>\(msg["role"] ?? "user")\n\(msg["content"] ?? "")<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}
