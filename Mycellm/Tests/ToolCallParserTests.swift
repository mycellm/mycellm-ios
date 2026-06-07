import XCTest
@testable import Mycellm

/// Mirrors tests/unit/test_openai_api_tools.py from the Python repo —
/// behaviour parity for tool-call extraction across the formats models
/// emit in the wild.
final class ToolCallParserTests: XCTestCase {

    // MARK: - <tool_call> XML

    func testBasicXMLToolCall() {
        let raw = "<tool_call>{\"name\": \"get_weather\", \"arguments\": {\"city\": \"SF\"}}</tool_call>"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "get_weather")
        XCTAssertTrue(result.toolCalls[0].arguments.contains("\"city\""))
        XCTAssertTrue(result.toolCalls[0].arguments.contains("\"SF\""))
        XCTAssertEqual(result.residualContent, "")
    }

    func testXMLToolCallWithPreambleAndPostamble() {
        let raw = """
        Let me check the weather.

        <tool_call>{"name": "get_weather", "arguments": {"city": "NYC"}}</tool_call>

        I'll let you know what I find.
        """
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertTrue(result.residualContent.contains("Let me check"))
        XCTAssertTrue(result.residualContent.contains("I'll let you know"))
    }

    func testMultipleSequentialXMLToolCalls() {
        let raw = """
        <tool_call>{"name": "get_weather", "arguments": {"city": "SF"}}</tool_call>
        <tool_call>{"name": "get_weather", "arguments": {"city": "NYC"}}</tool_call>
        """
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "get_weather")
        XCTAssertEqual(result.toolCalls[1].name, "get_weather")
    }

    func testParametersAliasForArguments() {
        let raw = "<tool_call>{\"name\": \"foo\", \"parameters\": {\"x\": 1}}</tool_call>"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "foo")
        XCTAssertTrue(result.toolCalls[0].arguments.contains("\"x\""))
    }

    func testFunctionAliasForName() {
        let raw = "<tool_call>{\"function\": \"bar\", \"arguments\": {}}</tool_call>"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "bar")
    }

    func testArgumentsAsJSONStringRoundtrips() {
        // OpenAI's wire-format arguments is a JSON string. Models that
        // already serialise it correctly should pass through unchanged.
        let raw = "<tool_call>{\"name\": \"x\", \"arguments\": \"{\\\"a\\\":1}\"}</tool_call>"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].arguments, "{\"a\":1}")
    }

    func testUnclosedXMLLeftInResidual() {
        let raw = "Some prelude<tool_call>{\"name\": \"x\""
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.residualContent.contains("Some prelude"))
        XCTAssertTrue(result.residualContent.contains("<tool_call>"))
    }

    func testMalformedJSONInXMLDropped() {
        // Inner isn't valid JSON — block silently dropped, nothing emitted.
        let raw = "before<tool_call>not even json</tool_call>after"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 0)
        // The dropped block does NOT round-trip into residual; expected.
        XCTAssertEqual(result.residualContent, "beforeafter")
    }

    // MARK: - <tools>[] multi-tool array

    func testMultiToolArray() {
        let raw = """
        <tools>[
          {"name": "a", "arguments": {}},
          {"name": "b", "arguments": {"x": 2}}
        ]</tools>
        """
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "a")
        XCTAssertEqual(result.toolCalls[1].name, "b")
    }

    // MARK: - ```json fences

    func testJSONFenceAsToolCall() {
        let raw = """
        Here's the call:
        ```json
        {"name": "search", "arguments": {"q": "swift"}}
        ```
        """
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "search")
        XCTAssertTrue(result.residualContent.contains("Here's the call"))
        XCTAssertFalse(result.residualContent.contains("```json"))
    }

    func testJSONFenceWithoutToolShape_KeptInContent() {
        // Plain JSON example — must NOT be stripped from content.
        let raw = """
        Use this shape:
        ```json
        {"foo": 1, "bar": 2}
        ```
        """
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.residualContent.contains("```json"))
        XCTAssertTrue(result.residualContent.contains("\"foo\""))
    }

    // MARK: - bare top-level JSON

    func testBareTopLevelJSONToolCall() {
        // Some models drop the <tool_call> wrapper entirely when
        // tool_choice is "required" or names a specific function.
        let raw = "{\"name\": \"forced\", \"arguments\": {\"x\": 1}}"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].name, "forced")
        XCTAssertEqual(result.residualContent, "")
    }

    func testBareJSONOnlyTriggersWhenShapeMatches() {
        // Plain JSON output that isn't a tool call (e.g. user asked for
        // JSON answer) must stay in content.
        let raw = "{\"answer\": 42}"
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.residualContent, raw)
    }

    // MARK: - System-prompt tool injection

    func testFormatToolsForSystemPromptIncludesToolName() {
        let toolJson: [String: AnyCodable] = [
            "name": AnyCodable("get_weather"),
            "description": AnyCodable("Return current weather for a city."),
            "parameters": AnyCodable([
                "type": "object",
                "properties": ["city": ["type": "string"]],
            ] as [String: Any]),
        ]
        let tool = OpenAIRoutes.Tool(type: "function", function: toolJson)
        let formatted = ToolCallParser.formatToolsForSystemPrompt([tool])
        XCTAssertTrue(formatted.contains("get_weather"))
        XCTAssertTrue(formatted.contains("<tool_call>"))
    }

    func testFormatToolsForSystemPromptEmptyArrayReturnsEmpty() {
        XCTAssertEqual(ToolCallParser.formatToolsForSystemPrompt([]), "")
    }

    // MARK: - No false positives on plain text

    func testPlainTextPassesThrough() {
        let raw = "The capital of France is Paris."
        let result = ToolCallParser.extract(from: raw)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.residualContent, raw)
    }
}
