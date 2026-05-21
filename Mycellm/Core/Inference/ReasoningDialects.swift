import Foundation

/// Per-model-family reasoning ("thinking") dialect lookup.
///
/// Different model families surface reasoning differently:
///   * Qwen3 (hybrid)        — chat template flag `enable_thinking=False` suppresses;
///                             when enabled, reasoning wraps in <think>...</think>
///   * Qwen3-Coder / Instruct-2507 — never emits reasoning
///   * DeepSeek-R1 family    — always wraps reasoning in <think>...</think>;
///                             no template flag to suppress
///   * GLM-4.x-Thinking       — wraps in <think>...</think>
///   * Gemini 2.0 Thinking    — wraps in <think>...</think>
///   * OpenAI o-series (via relay) — hidden by upstream API
///
/// This module is the single place to encode that variance. New families add
/// one line to `Dialects.entries`. Backends and the API layer call the
/// helpers below and never need to know which family they're dealing with.
///
/// Mirrors the Python reference at src/mycellm/inference/reasoning_dialects.py.
enum ReasoningDialects {

    struct Dialect: Sendable {
        /// Can the model emit reasoning at all? Drives capability advertisement.
        let supports: Bool
        /// apply_chat_template kwarg to pass when caller wants reasoning suppressed.
        /// Most families don't accept any — set to nil.
        let templateKwargSuppress: (key: String, value: Bool)?
        /// Tag pair the model emits to wrap reasoning. nil means no wrapping
        /// (or no reasoning at all). Used for split + strip in API layer.
        let outputTagPair: (open: String, close: String)?
        /// If true, the model always emits reasoning regardless of template flag
        /// (e.g. DeepSeek-R1). Callers can still strip it via outputTagPair.
        let alwaysThinks: Bool

        init(
            supports: Bool,
            templateKwargSuppress: (key: String, value: Bool)? = nil,
            outputTagPair: (open: String, close: String)? = ("<think>", "</think>"),
            alwaysThinks: Bool = false
        ) {
            self.supports = supports
            self.templateKwargSuppress = templateKwargSuppress
            self.outputTagPair = outputTagPair
            self.alwaysThinks = alwaysThinks
        }
    }

    static let nonThinking = Dialect(supports: false, outputTagPair: nil)

    /// Match by lowercased substring against model name. First match wins,
    /// so list more-specific patterns BEFORE more-general ones.
    static let entries: [(pattern: String, dialect: Dialect)] = [
        // Qwen3 non-thinking variants — explicit suppression list (matched first)
        ("qwen3-coder", nonThinking),
        ("qwen3-instruct-2507", nonThinking),
        ("qwen3-vl-instruct", nonThinking),

        // Qwen3 hybrid thinking models — template flag works
        ("qwen3", Dialect(
            supports: true,
            templateKwargSuppress: (key: "enable_thinking", value: false),
            outputTagPair: ("<think>", "</think>")
        )),

        // DeepSeek-R1 family — always thinks, no suppression flag
        ("deepseek-r1", Dialect(
            supports: true,
            templateKwargSuppress: nil,
            outputTagPair: ("<think>", "</think>"),
            alwaysThinks: true
        )),

        // GLM thinking variants
        ("glm-4-thinking", Dialect(supports: true, outputTagPair: ("<think>", "</think>"))),
        ("glm-4.6-thinking", Dialect(supports: true, outputTagPair: ("<think>", "</think>"))),

        // Gemini thinking (via relay)
        ("gemini-2.0-flash-thinking", Dialect(supports: true, outputTagPair: ("<think>", "</think>"))),

        // OpenAI o-series (via relay) — reasoning hidden by upstream API, not <think>-wrapped
        ("gpt-o1", Dialect(supports: true, outputTagPair: nil)),
        ("gpt-o3", Dialect(supports: true, outputTagPair: nil)),
        ("gpt-o4", Dialect(supports: true, outputTagPair: nil)),
    ]

    /// Return the Dialect for a model name. Default: non-thinking.
    static func dialectFor(_ modelName: String) -> Dialect {
        guard !modelName.isEmpty else { return nonThinking }
        let nameLower = modelName.lowercased()
        for (pattern, dialect) in entries where nameLower.contains(pattern) {
            return dialect
        }
        return nonThinking
    }

    /// Does this model family emit reasoning content at all?
    static func supportsThinking(_ modelName: String) -> Bool {
        dialectFor(modelName).supports
    }

    /// Template kwarg to pass when caller wants reasoning suppressed.
    /// Returns nil if the model doesn't accept any suppression flag.
    static func chatTemplateSuppressKwarg(_ modelName: String) -> (key: String, value: Bool)? {
        dialectFor(modelName).templateKwargSuppress
    }

    /// Split raw model output into (content, reasoningContent).
    ///
    /// If the model's dialect declares an outputTagPair (e.g. <think></think>),
    /// extract all such blocks into reasoningContent and remove from content.
    /// Returns (content, reasoningContent). reasoningContent is "" if none.
    ///
    /// Tolerates unbalanced tags: if an opener has no closer, the unclosed
    /// remainder is treated as reasoning (model was cut off mid-think).
    static func splitReasoning(_ text: String, modelName: String) -> (content: String, reasoning: String) {
        let dialect = dialectFor(modelName)
        guard let pair = dialect.outputTagPair else {
            return (text, "")
        }
        guard text.contains(pair.open) else {
            return (text, "")
        }

        var content = ""
        var reasoning: [String] = []
        var remaining = Substring(text)

        while let openRange = remaining.range(of: pair.open) {
            // Append everything before the open tag to content
            content += remaining[remaining.startIndex..<openRange.lowerBound]
            // Skip past the open tag
            let afterOpen = remaining[openRange.upperBound...]
            // Look for close
            if let closeRange = afterOpen.range(of: pair.close) {
                let thinkText = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                reasoning.append(thinkText.trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = afterOpen[closeRange.upperBound...]
            } else {
                // Unclosed think — treat rest as reasoning, stop
                reasoning.append(String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = Substring("")
                break
            }
        }
        content += remaining
        return (
            content.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning.filter { !$0.isEmpty }.joined(separator: "\n\n")
        )
    }
}

/// Streaming state machine for splitting <think>...</think> from a token stream.
///
/// Usage:
/// ```swift
/// let splitter = StreamingThinkSplitter(open: "<think>", close: "</think>")
/// for token in stream {
///     for (kind, chunk) in splitter.feed(token) {
///         // kind in .content / .reasoning
///         emit(kind, chunk)
///     }
/// }
/// for (kind, chunk) in splitter.flush() {
///     emit(kind, chunk)
/// }
/// ```
///
/// Handles tags that straddle chunk boundaries by buffering up to
/// `close.count - 1` characters. Tolerates unclosed think blocks
/// (flush emits the remainder as reasoning). Inert (always emits .content)
/// when tag pair is nil.
final class StreamingThinkSplitter {
    enum Kind: Sendable {
        case content
        case reasoning
    }

    private let openTag: String?
    private let closeTag: String?
    private let enabled: Bool
    private var buffer: String = ""
    private var inThink: Bool = false

    init(open: String?, close: String?) {
        self.openTag = open
        self.closeTag = close
        self.enabled = (open != nil) && (close != nil) && !(open?.isEmpty ?? true) && !(close?.isEmpty ?? true)
    }

    /// Convenience: build a splitter sized to the model's dialect tag pair.
    convenience init(modelName: String) {
        let d = ReasoningDialects.dialectFor(modelName)
        if let pair = d.outputTagPair {
            self.init(open: pair.open, close: pair.close)
        } else {
            self.init(open: nil, close: nil)
        }
    }

    /// Process one streamed token. Returns list of (kind, chunk) tuples to emit.
    func feed(_ token: String) -> [(Kind, String)] {
        guard !token.isEmpty else { return [] }
        guard enabled, let openTag = openTag, let closeTag = closeTag else {
            return [(.content, token)]
        }

        var out: [(Kind, String)] = []
        buffer += token

        while !buffer.isEmpty {
            if inThink {
                if let closeRange = buffer.range(of: closeTag) {
                    let prefix = buffer[buffer.startIndex..<closeRange.lowerBound]
                    if !prefix.isEmpty {
                        out.append((.reasoning, String(prefix)))
                    }
                    buffer = String(buffer[closeRange.upperBound...])
                    inThink = false
                    continue
                }
                // No close yet — emit all but trailing close-tag-length bytes
                let safe = buffer.count - (closeTag.count - 1)
                if safe > 0 {
                    let idx = buffer.index(buffer.startIndex, offsetBy: safe)
                    out.append((.reasoning, String(buffer[buffer.startIndex..<idx])))
                    buffer = String(buffer[idx...])
                }
                break
            } else {
                if let openRange = buffer.range(of: openTag) {
                    let prefix = buffer[buffer.startIndex..<openRange.lowerBound]
                    if !prefix.isEmpty {
                        out.append((.content, String(prefix)))
                    }
                    buffer = String(buffer[openRange.upperBound...])
                    inThink = true
                    continue
                }
                // No open yet — emit all but trailing open-tag-length bytes
                let safe = buffer.count - (openTag.count - 1)
                if safe > 0 {
                    let idx = buffer.index(buffer.startIndex, offsetBy: safe)
                    out.append((.content, String(buffer[buffer.startIndex..<idx])))
                    buffer = String(buffer[idx...])
                }
                break
            }
        }

        return out
    }

    /// Drain remaining buffer at end of stream.
    func flush() -> [(Kind, String)] {
        guard !buffer.isEmpty else { return [] }
        let kind: Kind = inThink ? .reasoning : .content
        let out = [(kind, buffer)]
        buffer = ""
        return out
    }
}
