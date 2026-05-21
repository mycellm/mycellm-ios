import XCTest
@testable import Mycellm

/// Mirrors tests/unit/test_reasoning_dialects.py from the Python repo.
/// Keeps the Swift port behaviourally aligned with the canonical reference.
final class ReasoningDialectsTests: XCTestCase {

    // MARK: - supportsThinking classification

    func testQwen3HybridThinkingTrue() {
        XCTAssertTrue(ReasoningDialects.supportsThinking("Qwen3-1.7B-mlx-4bit"))
        XCTAssertTrue(ReasoningDialects.supportsThinking("Qwen3-30B-A3B"))
    }

    func testQwen3NonThinkingVariantsFalse() {
        XCTAssertFalse(ReasoningDialects.supportsThinking("Qwen3-Coder-30B-A3B-Instruct-MLX-4bit"))
        XCTAssertFalse(ReasoningDialects.supportsThinking("Qwen3-Instruct-2507-7B"))
        XCTAssertFalse(ReasoningDialects.supportsThinking("Qwen3-VL-Instruct-7B"))
    }

    func testOlderQwenNonThinking() {
        XCTAssertFalse(ReasoningDialects.supportsThinking("Qwen2.5-Coder-7B-Instruct"))
        XCTAssertFalse(ReasoningDialects.supportsThinking("Qwen2.5-7B-Instruct-Q4_K_M"))
    }

    func testDeepSeekR1AlwaysThinks() {
        XCTAssertTrue(ReasoningDialects.supportsThinking("deepseek-r1-distill-llama-8b"))
        XCTAssertTrue(ReasoningDialects.supportsThinking("DeepSeek-R1-7B"))
    }

    func testGLMThinking() {
        XCTAssertTrue(ReasoningDialects.supportsThinking("GLM-4.6-Thinking"))
    }

    func testOpenAIOSeries() {
        XCTAssertTrue(ReasoningDialects.supportsThinking("gpt-o1-mini"))
        XCTAssertTrue(ReasoningDialects.supportsThinking("gpt-o3"))
    }

    func testNonThinkingBaselines() {
        XCTAssertFalse(ReasoningDialects.supportsThinking("llama-3.1-8b-instruct"))
        XCTAssertFalse(ReasoningDialects.supportsThinking(""))
        XCTAssertFalse(ReasoningDialects.supportsThinking("mistral-small-24b"))
    }

    // MARK: - chatTemplateSuppressKwarg

    func testQwen3HybridReturnsEnableThinkingFalse() {
        let kwarg = ReasoningDialects.chatTemplateSuppressKwarg("Qwen3-1.7B")
        XCTAssertEqual(kwarg?.key, "enable_thinking")
        XCTAssertEqual(kwarg?.value, false)
    }

    func testQwen3CoderReturnsNil() {
        XCTAssertNil(ReasoningDialects.chatTemplateSuppressKwarg("Qwen3-Coder-30B"))
    }

    func testDeepSeekR1ReturnsNil() {
        // R1 always thinks, no template flag works — strip output instead
        XCTAssertNil(ReasoningDialects.chatTemplateSuppressKwarg("deepseek-r1-distill-7b"))
    }

    // MARK: - splitReasoning (non-streaming)

    func testBasicSplit() {
        let text = "<think>Let me consider this</think>The answer is 42."
        let (content, reasoning) = ReasoningDialects.splitReasoning(text, modelName: "Qwen3-1.7B")
        XCTAssertEqual(content, "The answer is 42.")
        XCTAssertEqual(reasoning, "Let me consider this")
    }

    func testMultipleThinkBlocks() {
        let text = "<think>step one</think>Some content<think>step two</think>More content."
        let (content, reasoning) = ReasoningDialects.splitReasoning(text, modelName: "deepseek-r1-7b")
        XCTAssertEqual(content, "Some contentMore content.")
        XCTAssertTrue(reasoning.contains("step one"))
        XCTAssertTrue(reasoning.contains("step two"))
    }

    func testNoThinkBlock() {
        let (content, reasoning) = ReasoningDialects.splitReasoning("Just a plain answer.", modelName: "Qwen3-1.7B")
        XCTAssertEqual(content, "Just a plain answer.")
        XCTAssertEqual(reasoning, "")
    }

    func testUnclosedThink() {
        // Model cut off mid-thinking — treat remainder as reasoning
        let (content, reasoning) = ReasoningDialects.splitReasoning("<think>I'm still thinking and got cut off", modelName: "Qwen3-1.7B")
        XCTAssertEqual(content, "")
        XCTAssertTrue(reasoning.contains("still thinking"))
    }

    func testNonThinkingModelPassthrough() {
        // No outputTagPair for this dialect — text returns unchanged
        let text = "<think>this should NOT be stripped</think>kept verbatim"
        let (content, reasoning) = ReasoningDialects.splitReasoning(text, modelName: "Qwen3-Coder-30B")
        XCTAssertEqual(content, text)
        XCTAssertEqual(reasoning, "")
    }

    // MARK: - StreamingThinkSplitter

    func testStreamingCleanSplit() {
        let s = StreamingThinkSplitter(modelName: "Qwen3-1.7B")
        var emitted: [(StreamingThinkSplitter.Kind, String)] = []
        for chunk in ["<thi", "nk>so I", " should", "</thin", "k>The ", "answer ", "is 42."] {
            emitted.append(contentsOf: s.feed(chunk))
        }
        emitted.append(contentsOf: s.flush())
        let reasoning = emitted.filter { $0.0 == .reasoning }.map { $0.1 }.joined()
        let content = emitted.filter { $0.0 == .content }.map { $0.1 }.joined()
        XCTAssertTrue(reasoning.contains("so I should"))
        XCTAssertTrue(content.contains("The answer is 42."))
    }

    func testStreamingUnclosedThinkFlushesAsReasoning() {
        let s = StreamingThinkSplitter(modelName: "Qwen3-1.7B")
        var out = s.feed("<think>incomplete reasoning")
        out.append(contentsOf: s.flush())
        let kinds = Set(out.map(\.0))
        XCTAssertEqual(kinds, [.reasoning])
        let combined = out.map(\.1).joined()
        XCTAssertTrue(combined.contains("incomplete reasoning"))
    }

    func testStreamingNonThinkingModelPassthrough() {
        let s = StreamingThinkSplitter(modelName: "Qwen3-Coder-30B")
        var out = s.feed("<think>literal text</think>more")
        out.append(contentsOf: s.flush())
        let kinds = Set(out.map(\.0))
        XCTAssertEqual(kinds, [.content])
        XCTAssertEqual(out.map(\.1).joined(), "<think>literal text</think>more")
    }

    func testStreamingNoThinkBlock() {
        let s = StreamingThinkSplitter(modelName: "Qwen3-1.7B")
        var out = s.feed("Just an answer.")
        out.append(contentsOf: s.flush())
        XCTAssertEqual(Set(out.map(\.0)), [.content])
        XCTAssertEqual(out.map(\.1).joined(), "Just an answer.")
    }

    func testStreamingEmptyToken() {
        let s = StreamingThinkSplitter(modelName: "Qwen3-1.7B")
        XCTAssertTrue(s.feed("").isEmpty)
        XCTAssertTrue(s.flush().isEmpty)
    }

    func testStreamingMultipleThinkBlocks() {
        let s = StreamingThinkSplitter(modelName: "deepseek-r1-7b")
        let text = "<think>a</think>X<think>b</think>Y"
        var out: [(StreamingThinkSplitter.Kind, String)] = []
        for ch in text {
            out.append(contentsOf: s.feed(String(ch)))
        }
        out.append(contentsOf: s.flush())
        let reasoning = out.filter { $0.0 == .reasoning }.map(\.1).joined()
        let content = out.filter { $0.0 == .content }.map(\.1).joined()
        XCTAssertTrue(reasoning.contains("a"))
        XCTAssertTrue(reasoning.contains("b"))
        XCTAssertEqual(content, "XY")
    }

    // MARK: - dialectFor fallback

    func testUnknownModelIsNonThinking() {
        let d = ReasoningDialects.dialectFor("some-future-model-2030")
        XCTAssertFalse(d.supports)
        XCTAssertNil(d.outputTagPair)
        XCTAssertNil(d.templateKwargSuppress)
    }
}
