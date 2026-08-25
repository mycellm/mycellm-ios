import XCTest
@testable import Mycellm

/// `QueueClient` row parsing and the request it builds.
///
/// Parsing is tested against literal node payloads rather than a round-trip
/// through the encoder, because the failure this guards against is the node
/// and the app disagreeing about a field name — which a round-trip through
/// one side's own types cannot catch.
final class QueueClientTests: XCTestCase {

    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "job_id": "q_abc123",
            "state": "queued",
            "model": "",
            "min_tier": "frontier",
            "messages": [["role": "user", "content": "What is a mycelium?"]],
            "waiting_reason": "No frontier-tier model is reachable (1 model online below that tier).",
            "result_text": "",
            "error": "",
            "served_by": "",
            "served_model": "",
            "stake": 0.0,
            "created_at": 1_700_000_000.0,
            "position": 1,
        ]
        overrides.forEach { base[$0.key] = $0.value }
        return base
    }

    func testParsesAQueuedJob() throws {
        let job = try XCTUnwrap(QueueClient.parse(row()))
        XCTAssertEqual(job.id, "q_abc123")
        XCTAssertEqual(job.state, "queued")
        XCTAssertEqual(job.minTier, "frontier")
        XCTAssertEqual(job.prompt, "What is a mycelium?")
        XCTAssertEqual(job.position, 1)
    }

    func testWaitingReasonSurvivesParsing() throws {
        // The most important field on the screen. If it is ever dropped, the
        // queue becomes indistinguishable from a hang.
        let job = try XCTUnwrap(QueueClient.parse(row()))
        XCTAssertTrue(job.waitingReason.contains("frontier"))
    }

    func testPromptComesFromTheLastUserMessage() throws {
        let job = try XCTUnwrap(QueueClient.parse(row(["messages": [
            ["role": "system", "content": "be brief"],
            ["role": "user", "content": "first"],
            ["role": "assistant", "content": "reply"],
            ["role": "user", "content": "second"],
        ]])))
        XCTAssertEqual(job.prompt, "second")
    }

    func testMissingJobIDIsRejected() {
        // A row without an id cannot be cancelled or polled, so it must not
        // become a ghost entry in the list.
        XCTAssertNil(QueueClient.parse(["state": "queued"]))
    }

    func testAbsentFieldsDegradeToEmpty() throws {
        // A 0.8 node sends every field; being strict here would mean one
        // added field on the server breaking the whole list on older apps.
        let job = try XCTUnwrap(QueueClient.parse(["job_id": "q_1"]))
        XCTAssertEqual(job.state, "queued")
        XCTAssertEqual(job.prompt, "")
        XCTAssertEqual(job.waitingReason, "")
    }

    func testParsesAFinishedJobWithAttribution() throws {
        let job = try XCTUnwrap(QueueClient.parse(row([
            "state": "done",
            "result_text": "A mycelium is a fungal network.",
            "served_by": "4721c9de8f1a2b3c",
            "served_model": "qwen3-35b",
        ])))
        XCTAssertEqual(job.servedModel, "qwen3-35b")
        XCTAssertEqual(job.servedBy, "4721c9de8f1a2b3c")
        XCTAssertTrue(job.isTerminal)
    }

    func testTerminalStates() throws {
        for state in ["done", "failed", "expired", "cancelled"] {
            let job = try XCTUnwrap(QueueClient.parse(row(["state": state])))
            XCTAssertTrue(job.isTerminal, state)
        }
        for state in ["queued", "running"] {
            let job = try XCTUnwrap(QueueClient.parse(row(["state": state])))
            XCTAssertFalse(job.isTerminal, state)
        }
    }

    // MARK: - Endpoint derivation

    func testQueuePathIsDerivedFromTheChatEndpoint() {
        // Settings stores a full `…/v1/chat/completions` URL; the queue hangs
        // off the same root. Getting this wrong 404s every call, and the
        // symptom (an empty queue) looks exactly like an empty queue.
        let root = QueueClient.root(of: "https://api.mycellm.dev/v1/chat/completions")
        XCTAssertEqual(QueueClient.url(root: root, path: "/v1/jobs")?.absoluteString,
                       "https://api.mycellm.dev/v1/jobs")
    }

    func testRootIsAlreadyARootIsLeftAlone() {
        let root = QueueClient.root(of: "http://10.1.1.11:8420")
        XCTAssertEqual(QueueClient.url(root: root, path: "/v1/jobs")?.absoluteString,
                       "http://10.1.1.11:8420/v1/jobs")
    }

    func testTrailingSlashDoesNotDoubleUp() {
        let root = QueueClient.root(of: "http://10.1.1.11:8420/")
        XCTAssertEqual(QueueClient.url(root: root, path: "/v1/jobs")?.absoluteString,
                       "http://10.1.1.11:8420/v1/jobs")
    }

    func testEmptyOrGarbageEndpointYieldsNoURL() {
        XCTAssertNil(QueueClient.root(of: ""))
        XCTAssertNil(QueueClient.root(of: "   "))
        XCTAssertNil(QueueClient.root(of: "not a url"))
        XCTAssertNil(QueueClient.url(root: nil, path: "/v1/jobs"))
    }
}
