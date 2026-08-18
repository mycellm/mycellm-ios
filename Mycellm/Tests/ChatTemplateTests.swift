import XCTest
@testable import Mycellm

#if canImport(MLXLMCommon)
import MLXLMCommon

/// Prompt construction for the MLX backend.
///
/// ⚠️ THE BUG THESE GUARD AGAINST PRODUCED NO ERROR AT ALL. The backend
/// rendered ChatML by hand and encoded it directly, never asking the tokenizer
/// for the model's template. ChatML happens to be correct for Qwen2.5, Llama-3
/// and Mistral, so most models worked and the assumption looked sound — until
/// a family with its own template arrived. Qwen3.5 on an iPhone spent a whole
/// 400-token budget inside a `<think>` block that never closed, the reasoning
/// splitter stripped it, and the caller got `""` back with `finish_reason:
/// stop`. A correct model, correct weights, and no answer.
///
/// So the property under test is not "the prompt looks right" — it is **the
/// tokenizer's template is what gets used**, and the hand-rolled format is only
/// ever a last resort.
final class ChatTemplateTests: XCTestCase {

    // MARK: - Doubles

    /// Reports its own template output, so a test can tell which path ran.
    private struct TemplatedTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
        static let templateTokens = [9001, 9002, 9003]
        var throwsOnTemplate = false
        var returnsEmpty = false

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            // Distinguishable from the template path, and carries the length so
            // a test can tell a ChatML render happened at all.
            [7000, text.count]
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            if throwsOnTemplate { throw MycellmError.modelNotLoaded("no template") }
            if returnsEmpty { return [] }
            return Self.templateTokens
        }
    }

    private let messages: [[String: String]] = [
        ["role": "system", "content": "You are terse."],
        ["role": "user", "content": "Why is the sky blue?"],
    ]

    // MARK: - The template must be used

    func testPromptTokensComeFromTheModelsOwnTemplate() {
        let tokens = MLXBackend.promptTokens(
            TemplatedTokenizer(), messages: MLXBackend.asChatMessages(messages))
        XCTAssertEqual(tokens, TemplatedTokenizer.templateTokens,
                       "the tokenizer's chat template must be what builds the prompt")
    }

    func testTheHandRolledChatMLIsNotUsedWhenATemplateExists() {
        let tokens = MLXBackend.promptTokens(
            TemplatedTokenizer(), messages: MLXBackend.asChatMessages(messages))
        XCTAssertNotEqual(tokens.first, 7000,
                          "ChatML was encoded even though the model has a template")
    }

    // MARK: - Fallback, only when there is genuinely no template

    func testFallsBackToChatMLWhenTheTokenizerHasNoTemplate() {
        var t = TemplatedTokenizer(); t.throwsOnTemplate = true
        let tokens = MLXBackend.promptTokens(t, messages: MLXBackend.asChatMessages(messages))
        XCTAssertEqual(tokens.first, 7000, "a template-less tokenizer should still get a prompt")
    }

    func testAnEmptyTemplateResultFallsBackRatherThanPromptingWithNothing() {
        // An empty token array would generate from a blank prompt — the model
        // would answer something, unrelated to the conversation.
        var t = TemplatedTokenizer(); t.returnsEmpty = true
        let tokens = MLXBackend.promptTokens(t, messages: MLXBackend.asChatMessages(messages))
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(tokens.first, 7000)
    }

    // MARK: - Message widening

    func testWideningPreservesEveryRoleAndContent() {
        // The old code claimed these types were incompatible and hand-rolled a
        // prompt to avoid "translation glue". swift-transformers declares
        // `Message = [String: any Sendable]`; the conversion is this one line.
        let chat = MLXBackend.asChatMessages(messages)
        XCTAssertEqual(chat.count, 2)
        XCTAssertEqual(chat[0]["role"] as? String, "system")
        XCTAssertEqual(chat[0]["content"] as? String, "You are terse.")
        XCTAssertEqual(chat[1]["role"] as? String, "user")
        XCTAssertEqual(chat[1]["content"] as? String, "Why is the sky blue?")
    }

    func testWideningKeepsMessageOrder() {
        // Order is the conversation. A map that reordered would be silently
        // wrong in a way only long chats would show.
        let many: [[String: String]] = (0..<10).map {
            ["role": $0 % 2 == 0 ? "user" : "assistant", "content": "m\($0)"]
        }
        let chat = MLXBackend.asChatMessages(many)
        XCTAssertEqual(chat.map { $0["content"] as? String },
                       (0..<10).map { "m\($0)" })
    }
}
#endif
