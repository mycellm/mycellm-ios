import XCTest
@testable import Mycellm

/// Parity checks for the `/v1/node/activity` payload against
/// src/mycellm/activity.py — the shapes a dashboard reads by name.
final class ActivityTrackerTests: XCTestCase {

    // MARK: - Wire shape

    func testEventDictHasPythonEnvelope() {
        let tracker = ActivityTracker()
        tracker.record(.inferenceComplete, data: ["model": "qwen3", "tokens": 42])

        let events = tracker.recent()
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e["type"] as? String, "inference_complete")
        XCTAssertNotNil(e["timestamp"] as? Double)
        // "time" is the HH:MM:SS clock string Python renders alongside the epoch.
        XCTAssertEqual((e["time"] as? String)?.count, 8)
        // Data keys are spread into the top level, not nested under "data".
        XCTAssertEqual(e["model"] as? String, "qwen3")
        XCTAssertEqual(e["tokens"] as? Int, 42)
        XCTAssertNil(e["data"])
    }

    func testEventTypeRawValuesMatchPython() {
        XCTAssertEqual(ActivityTracker.EventType.inferenceComplete.rawValue, "inference_complete")
        XCTAssertEqual(ActivityTracker.EventType.inferenceFailed.rawValue, "inference_failed")
        XCTAssertEqual(ActivityTracker.EventType.modelLoaded.rawValue, "model_loaded")
        XCTAssertEqual(ActivityTracker.EventType.creditEarned.rawValue, "credit_earned")
        XCTAssertEqual(ActivityTracker.EventType.peerConnected.rawValue, "peer_connected")
        XCTAssertEqual(ActivityTracker.EventType.natDiscovered.rawValue, "nat_discovered")
        XCTAssertEqual(ActivityTracker.EventType.nodeStarted.rawValue, "node_started")
        XCTAssertEqual(ActivityTracker.EventType.nodeError.rawValue, "node_error")
    }

    // MARK: - Counters

    func testStatsCountRequestsTokensAndErrors() {
        let tracker = ActivityTracker()
        tracker.record(.inferenceComplete, data: ["model": "m", "tokens": 10])
        tracker.record(.inferenceComplete, data: ["model": "m", "tokens": 15])
        tracker.record(.inferenceFailed, data: ["model": "m", "error": "boom"])

        let stats = tracker.stats()
        XCTAssertEqual(stats["total_requests"] as? Int, 2)
        XCTAssertEqual(stats["total_tokens"] as? Int, 25)
        XCTAssertEqual(stats["total_errors"] as? Int, 1)
        XCTAssertEqual(stats["requests_5min"] as? Int, 2)
        XCTAssertEqual(stats["errors_5min"] as? Int, 1)
        XCTAssertEqual(stats["tokens_5min"] as? Int, 25)
    }

    func testStatsExposeEveryKeyPythonDoes() {
        let stats = ActivityTracker().stats()
        for key in [
            "total_requests", "total_tokens", "total_errors", "requests_per_min",
            "load", "requests_5min", "tokens_per_min", "tokens_5min",
            "errors_5min", "tps", "avg_latency_ms",
        ] {
            XCTAssertNotNil(stats[key], "missing stats key: \(key)")
        }
        let load = stats["load"] as? [String: Any]
        for key in ["req_1m", "req_5m", "req_15m", "tok_1m", "tok_5m", "tok_15m"] {
            XCTAssertNotNil(load?[key], "missing load key: \(key)")
        }
    }

    /// Events outside the window must not be counted — the whole point of the
    /// rolling figures is that they decay.
    func testOldEventsFallOutOfRollingWindows() {
        let tracker = ActivityTracker()
        tracker.record(.inferenceComplete, data: ["tokens": 100],
                       at: Date().addingTimeInterval(-1000))
        tracker.record(.inferenceComplete, data: ["tokens": 5])

        let stats = tracker.stats()
        XCTAssertEqual(stats["total_requests"] as? Int, 2, "lifetime counter keeps both")
        XCTAssertEqual(stats["requests_5min"] as? Int, 1, "only the recent one is in-window")
        XCTAssertEqual(stats["tokens_5min"] as? Int, 5)
    }

    func testAvgLatencyUsesOnlyEventsThatReportedOne() {
        let tracker = ActivityTracker()
        tracker.record(.inferenceComplete, data: ["tokens": 1, "latency_ms": 100.0])
        tracker.record(.inferenceComplete, data: ["tokens": 1])  // no latency
        tracker.record(.inferenceComplete, data: ["tokens": 1, "latency_ms": 300.0])

        XCTAssertEqual(tracker.stats()["avg_latency_ms"] as? Double, 200.0)
    }

    // MARK: - Filtering & bounds

    func testRecentFiltersByType() {
        let tracker = ActivityTracker()
        tracker.record(.inferenceComplete, data: ["tokens": 1])
        tracker.record(.modelLoaded, data: ["model": "a"])
        tracker.record(.modelLoaded, data: ["model": "b"])

        XCTAssertEqual(tracker.recent(eventType: "model_loaded").count, 2)
        XCTAssertEqual(tracker.recent(eventType: "inference_complete").count, 1)
        XCTAssertEqual(tracker.recent(eventType: "nope").count, 0)
        XCTAssertEqual(tracker.recent().count, 3, "no filter returns everything")
    }

    func testRecentReturnsNewestEventsWhenLimited() {
        let tracker = ActivityTracker()
        for i in 0..<10 { tracker.record(.modelLoaded, data: ["model": .string("m\(i)")]) }

        let events = tracker.recent(limit: 3)
        XCTAssertEqual(events.count, 3)
        // suffix(): oldest-first ordering within the newest slice, as Python's
        // events[-limit:] gives.
        XCTAssertEqual(events.first?["model"] as? String, "m7")
        XCTAssertEqual(events.last?["model"] as? String, "m9")
    }

    func testRingBufferEvictsOldest() {
        let tracker = ActivityTracker(maxEvents: 5)
        for i in 0..<20 { tracker.record(.modelLoaded, data: ["model": .string("m\(i)")]) }

        let events = tracker.recent(limit: 100)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.first?["model"] as? String, "m15")
        // The lifetime counter is unaffected by eviction.
        XCTAssertEqual(tracker.recent(limit: 0).count, 0)
    }

    // MARK: - Sparklines

    func testSparklineAccumulatesIntoMinuteBuckets() {
        let tracker = ActivityTracker()
        let twoMinutesAgo = Date().addingTimeInterval(-120)
        tracker.record(.inferenceComplete, data: ["tokens": 7], at: twoMinutesAgo)
        // A later event rotates the bucket the first one landed in.
        tracker.record(.inferenceComplete, data: ["tokens": 3])

        let requests = tracker.sparkline("requests", minutes: 30)
        let tokens = tracker.sparkline("tokens", minutes: 30)
        XCTAssertFalse(requests.isEmpty, "the rotated bucket is published")
        XCTAssertEqual(requests.reduce(0, +), 1, "only the rotated event is in a closed bucket")
        XCTAssertEqual(tokens.reduce(0, +), 7)
    }

    func testSparklineOfUnknownMetricIsZeros() {
        let tracker = ActivityTracker()
        tracker.record(.inferenceComplete, data: ["tokens": 1],
                       at: Date().addingTimeInterval(-120))
        tracker.record(.inferenceComplete, data: ["tokens": 1])
        XCTAssertTrue(tracker.sparkline("not_a_metric").allSatisfy { $0 == 0 })
    }

    // MARK: - Subscription

    func testSubscriberReceivesEvents() async {
        let tracker = ActivityTracker()
        let stream = tracker.subscribe()

        tracker.record(.modelLoaded, data: ["model": "qwen3"])

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.type, .modelLoaded)
        XCTAssertEqual(event?.data["model"]?.stringValue, "qwen3")
    }

    func testSubscriptionIsReleasedWhenStreamIsDropped() async {
        let tracker = ActivityTracker()
        do {
            let stream = tracker.subscribe()
            var iterator = stream.makeAsyncIterator()
            tracker.record(.nodeStarted)
            _ = await iterator.next()
            XCTAssertEqual(tracker.subscriberCount, 1)
        }
        // onTermination fires asynchronously after the stream is released.
        for _ in 0..<50 where tracker.subscriberCount > 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(tracker.subscriberCount, 0, "a dropped stream must not leak a subscriber")
    }

    /// A stalled consumer must never block `record()` — inference would stall
    /// behind a dashboard tab nobody is looking at.
    func testRecordDoesNotBlockOnAFullSubscriberBuffer() {
        let tracker = ActivityTracker()
        _ = tracker.subscribe()  // never drained
        for i in 0..<500 { tracker.record(.modelLoaded, data: ["model": .string("m\(i)")]) }
        XCTAssertEqual(tracker.stats()["total_requests"] as? Int, 0)
        XCTAssertEqual(tracker.recent(limit: 1).first?["model"] as? String, "m499")
    }

    // MARK: - UI-event bridge

    func testActivityItemKindsMapToWireEvents() {
        let cases: [(ActivityItem.Kind, String)] = [
            (.nodeStarted, "node_started"),
            (.nodeStopped, "node_stopped"),
            (.modelLoaded("m"), "model_loaded"),
            (.modelUnloaded("m"), "model_unloaded"),
            (.inferenceCompleted(model: "m", tokens: 1), "inference_complete"),
            (.httpServerStarted(8420), "http_server_started"),
            (.creditEarned(1.0, "peer"), "credit_earned"),
            (.creditSpent(1.0, "peer"), "credit_spent"),
            (.peerConnected("p"), "peer_connected"),
            (.peerDisconnected("p"), "peer_disconnected"),
            (.networkInfo(lan: "1", wan: "2", nat: "full"), "nat_discovered"),
            (.relayDiscovered(name: "r", models: 2), "relay_discovered"),
            (.error("bad"), "node_error"),
        ]
        for (kind, expected) in cases {
            XCTAssertEqual(kind.asActivityEvent.0.rawValue, expected)
        }
    }

    func testInferenceEventCarriesModelAndTokens() {
        let (type, data) = ActivityItem.Kind
            .inferenceCompleted(model: "qwen3", tokens: 99).asActivityEvent
        XCTAssertEqual(type, .inferenceComplete)
        XCTAssertEqual(data["model"]?.stringValue, "qwen3")
        XCTAssertEqual(data["tokens"]?.intValue, 99)
    }

    func testNodeStatsFeedsBothBuffers() {
        let stats = NodeStats()
        stats.addEvent(.inferenceCompleted(model: "qwen3", tokens: 20))

        XCTAssertEqual(stats.recentEvents.count, 1, "UI buffer")
        XCTAssertEqual(stats.activity.recent().count, 1, "API buffer")
        XCTAssertEqual(stats.activity.stats()["total_tokens"] as? Int, 20)
    }
}
