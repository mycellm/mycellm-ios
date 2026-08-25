import XCTest
@testable import Mycellm

/// Swarm progress frames, and the line they render.
///
/// These frames carry an **empty delta** by contract, so a client that only
/// concatenates `delta.content` is unaffected. Reading them is what turns the
/// several seconds a swarm spends fanning out from a dot animation that looks
/// exactly like a hang into "Asking 3 models on aurora, hokulea…".
final class SwarmProgressTests: XCTestCase {

    // MARK: - Parsing

    func testParsesProposingFrame() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "proposing", "planned": 3,
            "targets": ["peer:1a2b3c4d5e:qwen3-9b", "local:qwen3-35b"],
        ]))
        XCTAssertEqual(p.phase, .proposing)
        XCTAssertEqual(p.planned, 3)
        XCTAssertEqual(p.targets.count, 2)
    }

    func testParsesSynthesizingFrame() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "synthesizing",
            "target": "local:qwen3-35b", "from_proposals": 3,
        ]))
        XCTAssertEqual(p.phase, .synthesizing)
        XCTAssertEqual(p.fromProposals, 3)
    }

    func testFinalPlanIsNotAProgressFrame() {
        // The same `mycellm` field carries the execution plan when the job
        // finishes. Mistaking it for progress would leave a stale phase line
        // pinned under a completed answer.
        XCTAssertNil(SwarmProgress(mycellm: [
            "strategy": "swarm", "units_ok": 3, "job_id": "j1",
        ]))
    }

    func testUnknownPhaseIsRejected() {
        // A future phase name must not crash or render an empty label.
        XCTAssertNil(SwarmProgress(mycellm: ["type": "progress", "phase": "dreaming"]))
    }

    func testMissingFieldsDegradeToZero() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: ["type": "progress", "phase": "proposing"]))
        XCTAssertEqual(p.planned, 0)
        XCTAssertTrue(p.targets.isEmpty)
    }

    // MARK: - Labels

    func testProposingLabelNamesTheNodes() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "proposing", "planned": 2,
            "targets": ["peer:1a2b3c4d5e6f:qwen3-9b", "local:qwen3-35b"],
        ]))
        XCTAssertEqual(p.label, "Asking 2 models on 1a2b3c4d, this device…")
    }

    func testSingularIsNotPluralised() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "proposing", "planned": 1,
            "targets": ["local:m"],
        ]))
        XCTAssertTrue(p.label.hasPrefix("Asking 1 model on"))
        XCTAssertFalse(p.label.contains("1 models"))
    }

    func testDuplicateTargetsAreCollapsed() throws {
        // Three models on one peer should read as one place, not three.
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "proposing", "planned": 3,
            "targets": ["peer:aaaaaaaa:m1", "peer:aaaaaaaa:m2", "peer:aaaaaaaa:m3"],
        ]))
        XCTAssertEqual(p.label, "Asking 3 models on aaaaaaaa…")
    }

    func testPlannedFallsBackToTargetCount() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "proposing",
            "targets": ["local:a", "peer:bbbbbbbb:b"],
        ]))
        XCTAssertTrue(p.label.hasPrefix("Asking 2 models"))
    }

    func testSynthesizingLabel() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "synthesizing",
            "target": "peer:9f9f9f9f:qwen3-35b", "from_proposals": 3,
        ]))
        XCTAssertEqual(p.label, "Synthesising 3 answers on 9f9f9f9f…")
    }

    // MARK: - shortTarget

    func testLocalReadsAsThisDevice() {
        XCTAssertEqual(SwarmProgress.shortTarget("local:qwen3-9b"), "this device")
    }

    func testPeerIsTruncatedToEightChars() {
        XCTAssertEqual(SwarmProgress.shortTarget("peer:1a2b3c4d5e6f7890:m"), "1a2b3c4d")
    }

    func testNamedGroupUsesItsId() {
        XCTAssertEqual(SwarmProgress.shortTarget("group:abc123:qwen3-9b"), "abc123")
    }

    func testUnnamedGroupFallsThroughToTheModel() {
        // ⚠️ THE REGRESSION THIS EXISTS FOR. A serving group with no id prints
        // as `group:external:<model>`; naively taking the second segment
        // rendered "Asking 3 models on external" — three distinct models
        // collapsed into one meaningless word. Caught in a browser on the
        // dashboard, fixed on both sides.
        XCTAssertEqual(SwarmProgress.shortTarget("group:external:swarm-a"), "swarm-a")
    }

    func testUnnamedGroupsStayDistinct() throws {
        let p = try XCTUnwrap(SwarmProgress(mycellm: [
            "type": "progress", "phase": "proposing", "planned": 3,
            "targets": ["group:external:a", "group:external:b", "group:external:c"],
        ]))
        XCTAssertEqual(p.label, "Asking 3 models on a, b, c…")
    }

    func testGarbageTargetIsReturnedUnchangedNotEmpty() {
        // Better to show something odd than a blank where a node name goes.
        XCTAssertEqual(SwarmProgress.shortTarget("weird"), "weird")
        XCTAssertFalse(SwarmProgress.shortTarget("").isEmpty == false)
    }

    func testModelNamesContainingColonsSurvive() {
        XCTAssertEqual(SwarmProgress.shortTarget("group:external:relay:qwen3-9b"),
                       "relay:qwen3-9b")
    }
}
