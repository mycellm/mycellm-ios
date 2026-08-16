import XCTest
@testable import Mycellm

/// ⚠️ REGRESSION SUITE. A device whose only loaded model was
/// `all-MiniLM-L6-v2` answered every chat request with
/// `[unused34][unused20][unused22]…` — and returned it as **HTTP 200 with
/// finish_reason "stop"**, so no caller could tell a failure from an answer.
///
/// MiniLM/BERT-family models are encoder-only: no language-modelling head, so
/// the logits are meaningless and sampling lands in the vocabulary's reserved
/// `[unusedNN]` slots. The classification to prevent this already existed and
/// was already correct — `/v1/models/capabilities` reported `tags:
/// ["embedding"]` the whole time. Nothing consulted it before generating.
final class ChatCapabilityTests: XCTestCase {

    private func models(_ names: [String]) -> [ModelManager.LoadedModel] {
        names.map {
            ModelManager.LoadedModel(
                name: $0, filename: $0, sizeBytes: 1, scope: "public", loadedAt: Date())
        }
    }

    // MARK: - chatModels

    func testEmbeddingModelsAreNotChatModels() {
        let loaded = models(["all-MiniLM-L6-v2-Q4_K_M.gguf"])
        XCTAssertEqual(loaded.count, 1, "it is loaded")
        XCTAssertTrue(ModelManager.chatCapable(loaded).isEmpty, "but it cannot chat")
        XCTAssertTrue(ModelManager.onlyEmbedding(loaded))
    }

    func testChatModelsAreChatModels() {
        let loaded = models(["Qwen2.5-3B-Instruct-Q4_K_M.gguf"])
        XCTAssertEqual(ModelManager.chatCapable(loaded).count, 1)
        XCTAssertFalse(ModelManager.onlyEmbedding(loaded))
    }

    /// The mixed case must not be mistaken for the embedding-only one — a
    /// device with both can chat perfectly well.
    func testMixedLoadKeepsOnlyTheChatModel() {
        let loaded = models(["bge-small-en-v1.5.gguf", "Llama-3.2-3B-Instruct.gguf"])
        XCTAssertEqual(ModelManager.chatCapable(loaded).map(\.name),
                       ["Llama-3.2-3B-Instruct.gguf"])
        XCTAssertFalse(ModelManager.onlyEmbedding(loaded))
    }

    func testNothingLoadedIsNotTheEmbeddingOnlyState() {
        XCTAssertTrue(ModelManager.chatCapable([]).isEmpty)
        XCTAssertFalse(ModelManager.onlyEmbedding([]),
                       "no models at all is a different problem with a different message")
    }

    // MARK: - Role advertisement

    /// The node advertised `seeder` with only an embedding model loaded, so
    /// peers routed chat to a device that could only answer with garbage.
    /// Embedding execution is gated off too, so such a node serves nothing.
    @MainActor
    func testEmbeddingOnlyNodeIsNotASeeder() {
        let names = ["all-MiniLM-L6-v2-Q4_K_M.gguf"]
        let canServe = names.contains { !EmbeddingModels.isEmbeddingModel($0) }
        XCTAssertFalse(canServe)
        XCTAssertEqual(DeviceState.effectiveRole(hasLoadedModels: canServe), "consumer")
    }

    func testNodeWithAChatModelStillAdvertisesNormally() {
        let names = ["all-MiniLM-L6-v2-Q4_K_M.gguf", "Qwen2.5-3B-Instruct.gguf"]
        let canServe = names.contains { !EmbeddingModels.isEmbeddingModel($0) }
        XCTAssertTrue(canServe, "one chat model is enough to serve")
    }

    // MARK: - The refusal

    func testRefusalUsesTheOpenAIErrorEnvelope() {
        let body = OpenAIRoutes.errorBody(
            "all-MiniLM-L6-v2 is an embedding model and cannot generate text. "
            + "Load a chat model, or send this request to /v1/embeddings.",
            type: "invalid_request_error", code: "model_not_chat_capable")
        let error = body["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "model_not_chat_capable")
        XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    /// The message has to name the model and say what to do instead — a bare
    /// "unsupported" leaves the user staring at a model they just loaded.
    func testRefusalMessageIsActionable() {
        let msg = "all-MiniLM-L6-v2 is an embedding model and cannot generate text. "
            + "Load a chat model, or send this request to /v1/embeddings."
        XCTAssertTrue(msg.contains("all-MiniLM-L6-v2"), "names the model")
        XCTAssertTrue(msg.contains("Load a chat model"), "says what to do")
        XCTAssertTrue(msg.hasSuffix("."), "is a sentence")
    }

    // MARK: - The families that triggered it

    func testTheModelThatCausedThisIsClassifiedCorrectly() {
        XCTAssertTrue(EmbeddingModels.isEmbeddingModel("all-MiniLM-L6-v2-Q4_K_M.gguf"))
        XCTAssertEqual(EmbeddingModels.tags(for: "all-MiniLM-L6-v2-Q4_K_M.gguf"), ["embedding"])
    }
}
