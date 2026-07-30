import Foundation

/// Parses tool/function calls out of raw model output.
///
/// Models invoke tools in a few different formats depending on family +
/// chat-template version. This parser handles the patterns mycellm has
/// observed in the wild, mirroring `src/mycellm/api/openai.py`'s
/// `_parse_tool_call_xml` on the Python side:
///
/// 1. `<tool_call>{...JSON...}</tool_call>` — Qwen3-Coder, Hermes-2-Pro,
///    most function-calling fine-tunes. May contain multiple blocks.
/// 2. ` ```json\n{...}\n``` ` — many models reach for markdown JSON
///    fences when uncertain. Treated as a tool call when the JSON has
///    a "name" key and an "arguments"/"parameters" key.
/// 3. `<tools>[{...},{...}]</tools>` — older multi-tool format.
///
/// `ParsedToolCall.arguments` is the raw JSON string (per OpenAI
/// convention) so callers can pass it through without parsing twice.
///
/// `extract(from:)` returns the parsed calls AND the residual content
/// with all matched tool-call markup removed — so callers can use the
/// residual as the assistant message's `content` field while the
/// extracted calls populate `tool_calls`.
enum ToolCallParser {

    struct ParsedToolCall: Sendable, Equatable {
        let name: String
        /// Raw JSON string. Always valid JSON (parser validates).
        let arguments: String
    }

    struct Result: Sendable, Equatable {
        let toolCalls: [ParsedToolCall]
        let residualContent: String
    }

    /// Extract any tool calls from raw model output. Returns the calls
    /// found plus the input text with tool-call markup removed.
    static func extract(from raw: String) -> Result {
        var calls: [ParsedToolCall] = []
        var remaining = raw

        // Pattern 1: <tool_call>...</tool_call>
        remaining = extractAndStrip(
            pattern: "<tool_call>",
            close: "</tool_call>",
            from: remaining,
            into: &calls
        )

        // Pattern 1.5: envelope cut off by max_tokens — "<tool_call>{...}"
        // with no closing tag, possibly ending mid-"</tool_ca". Salvage the
        // JSON payload instead of surfacing a broken envelope as content.
        // (Mirror of the Python node's _recover_truncated_tool_call.)
        if calls.isEmpty, let openRange = remaining.range(of: "<tool_call>") {
            var payload = String(remaining[openRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let closing = "</tool_call>"
            for k in stride(from: closing.count, through: 1, by: -1) where payload.hasSuffix(String(closing.prefix(k))) {
                payload = String(payload.dropLast(k))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            if let call = parseSingleToolCallJSON(payload) {
                calls.append(call)
                remaining = String(remaining[remaining.startIndex..<openRange.lowerBound])
            }
        }

        // Pattern 2: <tools>[...]</tools> (multi-tool array)
        remaining = extractAndStripMulti(
            pattern: "<tools>",
            close: "</tools>",
            from: remaining,
            into: &calls
        )

        // Pattern 3: ```json fences containing tool-call-shaped JSON
        remaining = extractAndStripJSONFences(from: remaining, into: &calls)

        // Pattern 4: bare top-level JSON when the WHOLE response is a
        // single tool-call object (some models do this when tool_choice
        // is "required" or the explicit tool is named). Only triggers
        // when the trimmed residual is exactly a JSON object that looks
        // like {name, arguments}.
        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if calls.isEmpty, trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            if let call = parseSingleToolCallJSON(trimmed) {
                calls.append(call)
                remaining = ""
            }
        }

        return Result(
            toolCalls: calls,
            residualContent: remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Tagged extraction

    /// Extract <tool_call>JSON</tool_call> blocks. Each block is one call.
    private static func extractAndStrip(
        pattern open: String,
        close: String,
        from text: String,
        into calls: inout [ParsedToolCall]
    ) -> String {
        guard text.contains(open) else { return text }
        var residual = ""
        var remaining = Substring(text)

        while let openRange = remaining.range(of: open) {
            residual += remaining[remaining.startIndex..<openRange.lowerBound]
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                // Unclosed — keep raw in residual and stop
                residual += "\(open)\(afterOpen)"
                remaining = Substring("")
                break
            }
            let inner = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = parseSingleToolCallJSON(inner) {
                calls.append(call)
            }
            // (else: malformed block dropped from output)
            remaining = afterOpen[closeRange.upperBound...]
        }
        residual += remaining
        return residual
    }

    /// Extract <tools>[...]</tools> where inner is a JSON array of calls.
    private static func extractAndStripMulti(
        pattern open: String,
        close: String,
        from text: String,
        into calls: inout [ParsedToolCall]
    ) -> String {
        guard text.contains(open) else { return text }
        var residual = ""
        var remaining = Substring(text)

        while let openRange = remaining.range(of: open) {
            residual += remaining[remaining.startIndex..<openRange.lowerBound]
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                residual += "\(open)\(afterOpen)"
                remaining = Substring("")
                break
            }
            let inner = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = inner.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for obj in arr {
                    if let call = parseToolCallObject(obj) {
                        calls.append(call)
                    }
                }
            }
            remaining = afterOpen[closeRange.upperBound...]
        }
        residual += remaining
        return residual
    }

    /// Extract ```json fenced blocks whose JSON is shaped like a tool call.
    /// Non-tool-call JSON fences (e.g. user-facing JSON examples) stay in
    /// content untouched — we only strip when the JSON has `name` AND
    /// (`arguments` OR `parameters`).
    private static func extractAndStripJSONFences(
        from text: String,
        into calls: inout [ParsedToolCall]
    ) -> String {
        let fenceOpen = "```json"
        guard text.contains(fenceOpen) else { return text }

        var residual = ""
        var remaining = Substring(text)

        while let openRange = remaining.range(of: fenceOpen) {
            let beforeFence = remaining[remaining.startIndex..<openRange.lowerBound]
            let afterFence = remaining[openRange.upperBound...]

            // Skip the trailing newline after ```json if present
            let bodyStart = afterFence.first == "\n"
                ? afterFence.index(after: afterFence.startIndex)
                : afterFence.startIndex
            let body = afterFence[bodyStart...]

            guard let closeRange = body.range(of: "```") else {
                // Unclosed fence — keep raw in residual and stop
                residual += "\(beforeFence)\(fenceOpen)\(afterFence)"
                remaining = Substring("")
                break
            }
            let inner = String(body[body.startIndex..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let call = parseSingleToolCallJSON(inner) {
                // Looks like a tool call — strip from content, append.
                residual += beforeFence
                calls.append(call)
            } else {
                // Just a JSON example — keep it in content verbatim.
                // Half-open slice up to (but not past) the close fence's
                // upperBound to avoid Substring end-index OOB at endIndex.
                residual += "\(beforeFence)\(fenceOpen)\(body[body.startIndex..<closeRange.upperBound])"
            }
            remaining = body[closeRange.upperBound...]
        }
        residual += remaining
        return residual
    }

    // MARK: - JSON shape parsing

    /// Parse a single JSON object that should look like a tool call.
    /// Recognised shapes:
    ///   { "name": "x", "arguments": {...} }
    ///   { "name": "x", "arguments": "json-string" }
    ///   { "name": "x", "parameters": {...} }
    ///   { "function": "x", "arguments": ... }    // alternate key
    private static func parseSingleToolCallJSON(_ inner: String) -> ParsedToolCall? {
        guard let data = inner.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseToolCallObject(obj)
    }

    private static func parseToolCallObject(_ obj: [String: Any]) -> ParsedToolCall? {
        let nameKeys = ["name", "function", "tool"]
        let argKeys = ["arguments", "parameters", "args"]

        guard let name = nameKeys.compactMap({ obj[$0] as? String }).first, !name.isEmpty else {
            return nil
        }
        let argsValue = argKeys.compactMap { obj[$0] }.first ?? [:]

        // Normalise to JSON string per OpenAI convention.
        let argsString: String
        if let s = argsValue as? String {
            argsString = s
        } else if let data = try? JSONSerialization.data(withJSONObject: argsValue, options: [.sortedKeys]),
                  let s = String(data: data, encoding: .utf8) {
            argsString = s
        } else {
            return nil
        }

        return ParsedToolCall(name: name, arguments: argsString)
    }

    // MARK: - Tool injection (system prompt)

    /// Format a tools array into a system-prompt addendum understood by
    /// most function-calling fine-tunes (Qwen3, Hermes-2-Pro family).
    /// Returns a string to prepend to the system message OR insert as a
    /// new system message before user messages.
    static func formatToolsForSystemPrompt(_ tools: [OpenAIRoutes.Tool]) -> String {
        guard !tools.isEmpty else { return "" }
        var lines: [String] = []
        lines.append("You have access to the following tools:")
        for tool in tools {
            if let fn = tool.function {
                let asDict = fn.mapValues(\.value)
                if let data = try? JSONSerialization.data(withJSONObject: asDict, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    lines.append(json)
                }
            }
        }
        lines.append("")
        lines.append("To call a tool, emit exactly one block of the form:")
        lines.append("<tool_call>{\"name\": \"<tool_name>\", \"arguments\": <args-object>}</tool_call>")
        lines.append("If no tool is needed, answer normally.")
        return lines.joined(separator: "\n")
    }
}
