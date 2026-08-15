import XCTest
@testable import Mycellm

/// Mirrors the tag heuristics in src/mycellm/router/model_resolver.py. Both
/// sides classify from the same family list; a model that is an embedding model
/// on one node and a chat model on another routes wrongly on both.
final class EmbeddingModelsTests: XCTestCase {

    // MARK: - Recognition

    func testNamesThatSayEmbed() {
        for name in [
            "nomic-embed-text-v1.5",
            "snowflake-arctic-embed-m",
            "jina-embeddings-v2-base-en",
            "text-embedding-3-small",
        ] {
            XCTAssertTrue(EmbeddingModels.isEmbeddingModel(name), name)
        }
    }

    /// The families the original "embed" substring rule missed — every one of
    /// these ships as GGUF and was being tagged "chat".
    func testArchitectureNamedFamilies() {
        for name in [
            "all-MiniLM-L6-v2",
            "bge-small-en-v1.5",
            "gte-base",
            "multilingual-e5-large",
            "mxbai-embed-large-v1",
            "all-mpnet-base-v2",
            "sentence-t5-base",
            "paraphrase-multilingual-MiniLM-L12-v2",
        ] {
            XCTAssertTrue(EmbeddingModels.isEmbeddingModel(name), name)
        }
    }

    func testChatModelsAreNotEmbeddingModels() {
        for name in [
            "Qwen2.5-7B-Instruct",
            "Llama-3.2-3B-Instruct",
            "qwen3-1.7b",
            "Mistral-7B-Instruct-v0.3",
            "DeepSeek-R1-Distill-Qwen-7B",
            "gemma-3-4b-it",
            "phi-3.5-mini-instruct",
        ] {
            XCTAssertFalse(EmbeddingModels.isEmbeddingModel(name), name)
        }
    }

    func testMatchIsCaseInsensitiveAndIgnoresQuantSuffixAndPath() {
        XCTAssertTrue(EmbeddingModels.isEmbeddingModel("ALL-MINILM-L6-V2"))
        XCTAssertTrue(EmbeddingModels.isEmbeddingModel("bge-small-en-v1.5-Q4_K_M.gguf"))
        XCTAssertTrue(EmbeddingModels.isEmbeddingModel("/var/models/nomic-embed-text.gguf"))
        XCTAssertFalse(EmbeddingModels.isEmbeddingModel("/embeddings/Qwen2.5-7B.gguf"),
                       "a directory named embeddings must not classify the model inside it")
    }

    // MARK: - Tags

    func testEmbeddingTagOverridesRatherThanAppends() {
        // An embedding model that is not also a chat model — listing both would
        // let auto-routing pick it for a chat request, which it cannot serve.
        XCTAssertEqual(EmbeddingModels.tags(for: "bge-small-en"), ["embedding"])
        XCTAssertEqual(EmbeddingModels.tags(for: "nomic-embed-text"), ["embedding"])
    }

    func testChatTagsMatchPythonDeriveTags() {
        XCTAssertEqual(EmbeddingModels.tags(for: "Llama-3.2-3B-Instruct"), ["chat"])
        XCTAssertEqual(EmbeddingModels.tags(for: "Qwen2.5-Coder-7B"), ["chat", "code"])
        XCTAssertEqual(EmbeddingModels.tags(for: "QwQ-32B-Preview"), ["chat", "reasoning"])
        XCTAssertTrue(EmbeddingModels.tags(for: "Qwen2.5-VL-7B").contains("vision"))
    }

    // MARK: - Normalisation

    func testL2NormalizeProducesUnitVector() {
        let v = LlamaCppBackend.l2Normalize([3, 4])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-9)
        let magnitude = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-9)
    }

    func testL2NormalizeLeavesZeroVectorAlone() {
        // Dividing by a zero norm would fill the vector with NaN and poison
        // every downstream cosine similarity.
        XCTAssertEqual(LlamaCppBackend.l2Normalize([0, 0, 0]), [0, 0, 0])
    }

    // MARK: - Capability advertisement

    /// `supports_embeddings` must track the execution gate, not just the model
    /// name. Advertising true while the path is disabled routes every
    /// embeddings client to a node that will 400 them.
    func testCapabilityAdvertisementHonoursTheExecutionGate() {
        let manager = ModelManager()
        let caps = OpenAIRoutes.listCapabilities(manager: manager)
        let models = caps["models"] as? [[String: Any]] ?? []
        for m in models {
            let advertised = m["supports_embeddings"] as? Bool ?? false
            XCTAssertFalse(
                advertised && !LlamaCppBackend.embeddingsEnabled,
                "advertised embeddings support while execution is gated off")
        }
    }

    // MARK: - Batch context sizing

    /// ⚠️ REGRESSION: llama.cpp's `n_ctx` is the total across sequences and is
    /// divided by `n_seq_max` to get each sequence's window. Sizing it to the
    /// token total gave every sequence a fraction of what it needed, and
    /// llama.cpp answers that by calling abort() — the app died on the first
    /// multi-input request while a single input worked fine (n_seq_max 1 makes
    /// the division a no-op, which is what hid it).
    func testBatchContextGivesEverySequenceRoomForTheLongest() {
        func perSequenceWindow(_ lengths: [Int]) -> Int {
            let nCtx = LlamaCppBackend.embeddingContextSize(
                longest: lengths.max() ?? 0, sequences: lengths.count)
            return nCtx / max(1, lengths.count)
        }

        for lengths in [[8], [8, 8, 8], [3, 12, 5], [1, 1, 1, 1, 512], [512, 7]] {
            let window = perSequenceWindow(lengths)
            XCTAssertGreaterThanOrEqual(
                window, lengths.max()!,
                "each of \(lengths.count) sequences needs room for the longest (\(lengths.max()!)), got \(window)")
        }
    }

    func testSingleInputSizingIsUnchanged() {
        // The one case that always worked must not regress into over-allocation.
        XCTAssertEqual(LlamaCppBackend.embeddingContextSize(longest: 11, sequences: 1), 11)
    }
}
