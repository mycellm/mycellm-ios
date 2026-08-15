import XCTest
@testable import Mycellm

/// Parity checks for the node-management and OpenAI surfaces that don't need a
/// running node — request/response shapes, auth classification and the version
/// comparison behind `/v1/node/version`.
final class NodeAPITests: XCTestCase {

    // MARK: - Auth classification

    func testManagementSurfaceIsGated() {
        for path in [
            "/v1/node/status", "/v1/node/version", "/v1/node/peers",
            "/v1/node/connections", "/v1/node/activity", "/v1/node/activity/stream",
            "/v1/node/logs", "/v1/node/logs/stream",
            "/v1/node/models/local", "/v1/node/models/downloads/abort",
            "/v1/node/models/update", "/v1/node/models/reload",
        ] {
            XCTAssertTrue(NodeAuth.isProtected(path), "\(path) must require a key")
        }
    }

    func testInferenceAndScrapeSurfacesAreOpen() {
        for path in [
            "/health", "/metrics",
            "/v1/models", "/v1/models/capabilities", "/v1/models/qwen3",
            "/v1/chat/completions", "/v1/embeddings", "/v1/completions",
        ] {
            XCTAssertFalse(NodeAuth.isProtected(path), "\(path) must not require a key")
        }
    }

    /// `/metrics` is public in Python's `_PUBLIC_PATHS`; a scrape target behind
    /// a credential is one nobody configures.
    func testMetricsIsPublic() {
        XCTAssertFalse(NodeAuth.isProtected("/metrics"))
    }

    // MARK: - Version comparison

    func testIsNewerComparesNumerically() {
        XCTAssertTrue(NodeRoutes.isNewer("1.2.0", than: "1.1.0"))
        XCTAssertTrue(NodeRoutes.isNewer("1.10.0", than: "1.9.0"), "10 > 9, not '10' < '9'")
        XCTAssertTrue(NodeRoutes.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertTrue(NodeRoutes.isNewer("1.1.1", than: "1.1.0"))
    }

    func testIsNewerIsFalseForSameOrOlder() {
        XCTAssertFalse(NodeRoutes.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(NodeRoutes.isNewer("1.1.0", than: "1.2.0"))
        XCTAssertFalse(NodeRoutes.isNewer("1.2", than: "1.2.0"), "1.2 == 1.2.0")
    }

    /// An update prompt driven by a version string we can't parse is worse than
    /// no prompt at all.
    func testUnparseableVersionsAreNotNewer() {
        XCTAssertFalse(NodeRoutes.isNewer("", than: "1.0.0"))
        XCTAssertFalse(NodeRoutes.isNewer("latest", than: "1.0.0"))
        XCTAssertFalse(NodeRoutes.isNewer("1.x.0", than: "1.0.0"))
        XCTAssertFalse(NodeRoutes.isNewer("1.2.0", than: "not-a-version"))
    }

    // MARK: - Embeddings request decoding

    private func decodeEmbeddings(_ json: String) -> OpenAIRoutes.EmbeddingsRequest? {
        try? JSONDecoder().decode(
            OpenAIRoutes.EmbeddingsRequest.self, from: Data(json.utf8))
    }

    func testEmbeddingsAcceptsStringAndArrayInput() {
        XCTAssertEqual(decodeEmbeddings(#"{"input": "hello"}"#)?.input?.texts, ["hello"])
        XCTAssertEqual(decodeEmbeddings(#"{"input": ["a", "b"]}"#)?.input?.texts, ["a", "b"])
    }

    /// A token array must decode to `.unsupported`, not fail the whole body —
    /// otherwise the client gets a parse error instead of the `invalid_input`
    /// message telling it to send strings.
    func testTokenArrayInputDecodesToUnsupportedRatherThanThrowing() {
        let req = decodeEmbeddings(#"{"input": [1, 2, 3]}"#)
        XCTAssertNotNil(req, "the body must still decode")
        XCTAssertNil(req?.input?.texts)

        let nested = decodeEmbeddings(#"{"input": [[1, 2], [3, 4]]}"#)
        XCTAssertNotNil(nested)
        XCTAssertNil(nested?.input?.texts)
    }

    func testEmptyArrayIsSupportedButEmpty() {
        // Distinct from unsupported: the route answers "must be non-empty".
        XCTAssertEqual(decodeEmbeddings(#"{"input": []}"#)?.input?.texts, [])
    }

    /// A request with no `model` key is valid — Python's model defaults to "".
    /// Synthesised `Codable` would reject it outright (default values are not
    /// consulted for missing keys), which is why the decoder is hand-written.
    func testModelDefaultsToEmpty() {
        XCTAssertEqual(decodeEmbeddings(#"{"input": "x"}"#)?.model, "")
        XCTAssertEqual(decodeEmbeddings(#"{"input": "x", "model": "bge"}"#)?.model, "bge")
    }

    /// An absent `input` must stay distinguishable from a present-but-
    /// unsupported one: the route answers them with different messages.
    func testMissingInputIsNilRatherThanUnsupported() {
        let req = decodeEmbeddings(#"{"model": "bge"}"#)
        XCTAssertNotNil(req, "a body with only a model still decodes")
        XCTAssertNil(req?.input)
    }

    func testNonObjectBodyFailsToDecode() {
        XCTAssertNil(decodeEmbeddings("[1, 2, 3]"))
        XCTAssertNil(decodeEmbeddings("not json"))
    }

    // MARK: - Embeddings response shape

    func testEmbeddingsBodyMatchesOpenAI() {
        let result = EmbeddingResult(embeddings: [[0.1, 0.2], [0.3, 0.4]], totalTokens: 7)
        let body = OpenAIRoutes.embeddingsBody(result, model: "bge-small-en")

        XCTAssertEqual(body["object"] as? String, "list")
        XCTAssertEqual(body["model"] as? String, "bge-small-en")

        let data = body["data"] as? [[String: Any]]
        XCTAssertEqual(data?.count, 2)
        XCTAssertEqual(data?[0]["object"] as? String, "embedding")
        XCTAssertEqual(data?[0]["index"] as? Int, 0)
        XCTAssertEqual(data?[1]["index"] as? Int, 1)
        XCTAssertEqual(data?[1]["embedding"] as? [Double], [0.3, 0.4])

        // An embeddings request generates nothing, so the two token counts are
        // equal by definition — same as Python.
        let usage = body["usage"] as? [String: Any]
        XCTAssertEqual(usage?["prompt_tokens"] as? Int, 7)
        XCTAssertEqual(usage?["total_tokens"] as? Int, 7)
    }

    func testErrorBodyUsesOpenAIEnvelope() {
        let body = OpenAIRoutes.errorBody(
            "nope", type: "invalid_request_error", code: "embeddings_not_supported")
        let error = body["error"] as? [String: Any]
        XCTAssertEqual(error?["message"] as? String, "nope")
        XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
        XCTAssertEqual(error?["code"] as? String, "embeddings_not_supported")
    }

    func testEmbeddingsBodyIsJSONSerializable() {
        let body = OpenAIRoutes.embeddingsBody(
            EmbeddingResult(embeddings: [[0.5]], totalTokens: 1), model: "m")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    // MARK: - Model retrieval

    func testRetrieveUnknownModelIsNil() {
        // nil is what the router turns into a 404. An OpenAI client reads a
        // 200-with-error as success and carries on with a model that isn't there.
        let manager = ModelManager()
        XCTAssertNil(OpenAIRoutes.retrieveModel(id: "nope", manager: manager))
    }

    func testAutoIsNotServedWithNothingLoaded() {
        let manager = ModelManager()
        XCTAssertNil(OpenAIRoutes.retrieveModel(id: "auto", manager: manager),
                     "a node with no model cannot serve 'auto'")
    }

    // MARK: - Log broadcaster

    func testLogEntryShapeMatchesPython() {
        let broadcaster = LogBroadcaster()
        broadcaster.info("mycellm.node", "started")

        let logs = broadcaster.recent()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0]["level"] as? String, "INFO")
        XCTAssertEqual(logs[0]["name"] as? String, "mycellm.node")
        XCTAssertEqual(logs[0]["message"] as? String, "started")
        XCTAssertEqual((logs[0]["time"] as? String)?.count, 8)
    }

    func testLogBufferIsBounded() {
        let broadcaster = LogBroadcaster(maxLen: 3)
        for i in 0..<10 { broadcaster.info("t", "line \(i)") }

        let logs = broadcaster.recent(limit: 100)
        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs.first?["message"] as? String, "line 7")
        XCTAssertEqual(logs.last?["message"] as? String, "line 9")
    }

    func testLogSubscriberReceivesEntries() async {
        let broadcaster = LogBroadcaster()
        let stream = broadcaster.subscribe()
        broadcaster.warning("mycellm.api", "slow")

        var iterator = stream.makeAsyncIterator()
        let entry = await iterator.next()
        XCTAssertEqual(entry?.level, .warning)
        XCTAssertEqual(entry?.message, "slow")
    }

    // MARK: - SSE framing

    func testSSEFrameIsPythonCompatible() {
        // No `event:` name — Python's EventSourceResponse sends the payload as
        // the default `message` event, which is what clients listen for.
        XCTAssertEqual(
            SSEResponse.frameText(["type": "node_started"]),
            "data: {\"type\":\"node_started\"}\n\n"
        )
    }

    func testSSEFrameRejectsUnserializableObjects() {
        // A Date in the payload must yield nil, not crash the stream task.
        XCTAssertNil(SSEResponse.frameText(["bad": Date()]))
    }
}
