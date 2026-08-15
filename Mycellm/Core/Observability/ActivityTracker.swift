import Foundation

/// Node activity — the event ring, rolling statistics and per-minute sparkline
/// buckets behind `/v1/node/activity` and `/v1/node/activity/stream`.
///
/// ⚠️ THE WIRE SHAPE IS PYTHON'S, NOT THE UI'S, and the distinction is the
/// whole reason this type exists next to `NodeStats.recentEvents`. That array
/// holds `ActivityItem` — an enum with associated values, shaped for SwiftUI
/// and useless to an HTTP client. Every API consumer (the dashboard above all)
/// expects `ActivityEvent.to_dict()` from `src/mycellm/activity.py`: a flat
/// `{type, timestamp, time, ...data}` object with snake_case type strings.
/// Rendering the UI enum into that shape at request time would have meant
/// re-deriving rolling counters and sparklines on every poll from a 100-entry
/// buffer that drops the data those stats need. So both are fed from the same
/// call site — `NodeStats.addEvent` — and neither is derived from the other.
final class ActivityTracker: @unchecked Sendable {

    /// Event vocabulary. Raw values are Python's `EventType` verbatim; a
    /// dashboard cannot tell an iOS node from a Linux one by reading these.
    ///
    /// Python defines several types an iOS node never produces (`route_decision`,
    /// `fleet_node_joined`, `peer_exchange_received`, `connection_health`,
    /// `address_changed`, `network_selfheal`, `model_quarantined`) — they are
    /// omitted rather than declared-and-never-emitted. The last four cases are
    /// the reverse: real iOS events with no Python counterpart. Consumers treat
    /// unknown types generically, so both directions are safe.
    enum EventType: String, Sendable {
        case inferenceComplete = "inference_complete"
        case inferenceFailed = "inference_failed"
        case peerConnected = "peer_connected"
        case peerDisconnected = "peer_disconnected"
        case modelLoaded = "model_loaded"
        case modelUnloaded = "model_unloaded"
        case creditEarned = "credit_earned"
        case creditSpent = "credit_spent"
        case natDiscovered = "nat_discovered"
        case nodeStarted = "node_started"
        case nodeError = "node_error"

        // iOS-only — no Python counterpart.
        case nodeStopped = "node_stopped"
        case networkModeChanged = "network_mode_changed"
        case httpServerStarted = "http_server_started"
        case relayDiscovered = "relay_discovered"
    }

    /// One value in an event payload.
    ///
    /// ⚠️ NOT `Any`. Events cross an `AsyncStream` to reach SSE subscribers, and
    /// `AsyncStream.Element` must be `Sendable` — a `[String: Any]` payload
    /// cannot be, and `@unchecked` would be a lie here rather than a shortcut:
    /// the dictionary really would be free to carry a reference type across
    /// isolation domains. Every value these events actually hold is a scalar,
    /// so enumerating them costs nothing and makes the JSON conversion total.
    enum Value: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByFloatLiteral {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        init(stringLiteral value: String) { self = .string(value) }
        init(integerLiteral value: Int) { self = .int(value) }
        init(floatLiteral value: Double) { self = .double(value) }

        /// JSON-serializable projection.
        var asAny: Any {
            switch self {
            case .string(let s): s
            case .int(let i): i
            case .double(let d): d
            case .bool(let b): b
            }
        }

        var intValue: Int? {
            switch self {
            case .int(let i): i
            case .double(let d): Int(d)
            default: nil
            }
        }

        var doubleValue: Double? {
            switch self {
            case .double(let d): d
            case .int(let i): Double(i)
            default: nil
            }
        }

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }
    }

    /// One recorded event, already flattened to its wire form.
    struct Event: Sendable {
        let type: EventType
        let timestamp: Date
        let data: [String: Value]

        /// `ActivityEvent.to_dict()` — `data` is spread into the top level, so a
        /// key named `type`, `timestamp` or `time` would shadow the envelope.
        /// Callers don't use those names; the spread order matches Python's.
        var asDict: [String: Any] {
            var out: [String: Any] = [
                "type": type.rawValue,
                "timestamp": timestamp.timeIntervalSince1970,
                "time": ActivityTracker.clockFormatter.string(from: timestamp),
            ]
            for (k, v) in data { out[k] = v.asAny }
            return out
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Per-minute counters for the sparklines.
    private struct Bucket {
        var requests: Int = 0
        var tokens: Int = 0
        var errors: Int = 0
        var creditsEarned: Double = 0
        var creditsSpent: Double = 0
        var minute: Int = 0

        func value(for metric: String) -> Double {
            switch metric {
            case "requests": Double(requests)
            case "tokens": Double(tokens)
            case "errors": Double(errors)
            case "credits_earned": creditsEarned
            case "credits_spent": creditsSpent
            case "minute": Double(minute)
            default: 0
            }
        }
    }

    private let maxEvents: Int
    private let sparklineMinutes: Int

    private let lock = NSLock()
    private var events: [Event] = []
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

    private var requestCount = 0
    private var tokenCount = 0
    private var errorCount = 0

    private var minuteBuckets: [Bucket] = []
    private var currentMinute: Int = 0
    private var currentBucket = Bucket()

    init(maxEvents: Int = 1000, sparklineMinutes: Int = 60) {
        self.maxEvents = maxEvents
        self.sparklineMinutes = sparklineMinutes
    }

    // MARK: - Recording

    /// Record an event and fan it out to SSE subscribers.
    ///
    /// Safe to call from any isolation domain — this is why the type is a
    /// lock-guarded class rather than an actor. `NodeStats.addEvent` is
    /// synchronous and called from non-async contexts throughout the app;
    /// making it hop to an actor would have reordered events relative to the
    /// UI buffer they are supposed to mirror.
    func record(_ type: EventType, data: [String: Value] = [:], at date: Date = Date()) {
        let event = Event(type: type, timestamp: date, data: data)

        lock.lock()
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }

        rotateBucketLocked(now: date)
        switch type {
        case .inferenceComplete:
            requestCount += 1
            currentBucket.requests += 1
            let tokens = data["tokens"]?.intValue ?? 0
            tokenCount += tokens
            currentBucket.tokens += tokens
        case .inferenceFailed:
            errorCount += 1
            currentBucket.errors += 1
        case .creditEarned:
            currentBucket.creditsEarned += data["amount"]?.doubleValue ?? 0
        case .creditSpent:
            currentBucket.creditsSpent += data["amount"]?.doubleValue ?? 0
        default:
            break
        }
        let targets = Array(subscribers.values)
        lock.unlock()

        // Yielded outside the lock: a continuation's buffering policy runs on
        // yield, and holding the lock across it would let a consumer's teardown
        // deadlock against a concurrent record().
        for continuation in targets { continuation.yield(event) }
    }

    /// Roll the current per-minute bucket over, filling any gap with empties so
    /// a quiet node produces a flat sparkline rather than a compressed one.
    private func rotateBucketLocked(now: Date) {
        let nowMinute = Int(now.timeIntervalSince1970 / 60)
        guard nowMinute != currentMinute else { return }
        if currentMinute > 0 {
            currentBucket.minute = currentMinute
            minuteBuckets.append(currentBucket)
            let gap = min(nowMinute - currentMinute, sparklineMinutes)
            if gap > 1 {
                for _ in 0..<(gap - 1) { minuteBuckets.append(Bucket()) }
            }
            if minuteBuckets.count > sparklineMinutes {
                minuteBuckets.removeFirst(minuteBuckets.count - sparklineMinutes)
            }
        }
        currentMinute = nowMinute
        currentBucket = Bucket()
    }

    // MARK: - Reads

    /// Most recent events, oldest first, optionally filtered by type.
    func recent(limit: Int = 50, eventType: String? = nil) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        var list = events
        if let eventType, !eventType.isEmpty {
            list = list.filter { $0.type.rawValue == eventType }
        }
        return list.suffix(max(0, limit)).map(\.asDict)
    }

    /// Tokens per second over a rolling 60s window.
    var tps: Double {
        lock.lock()
        defer { lock.unlock() }
        return tpsLocked(now: Date())
    }

    private func tpsLocked(now: Date) -> Double {
        let tokens = events.reduce(0) { acc, e in
            guard e.type == .inferenceComplete,
                  now.timeIntervalSince(e.timestamp) < 60 else { return acc }
            return acc + (e.data["tokens"]?.intValue ?? 0)
        }
        return tokens > 0 ? ((Double(tokens) / 60.0) * 10).rounded() / 10 : 0
    }

    /// Mean latency of the last 20 completions that reported one.
    private func avgLatencyMsLocked() -> Double {
        let recent = events
            .compactMap { e -> Double? in
                guard e.type == .inferenceComplete else { return nil }
                guard let ms = e.data["latency_ms"]?.doubleValue, ms > 0 else { return nil }
                return ms
            }
            .suffix(20)
        guard !recent.isEmpty else { return 0 }
        return (recent.reduce(0, +) / Double(recent.count)).rounded()
    }

    /// Rolling statistics — the `stats` block of `/v1/node/activity`.
    func stats() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()

        func countRequests(within seconds: TimeInterval) -> Int {
            events.reduce(0) { acc, e in
                acc + (e.type == .inferenceComplete && now.timeIntervalSince(e.timestamp) < seconds ? 1 : 0)
            }
        }
        func countTokens(within seconds: TimeInterval) -> Int {
            events.reduce(0) { acc, e in
                guard e.type == .inferenceComplete,
                      now.timeIntervalSince(e.timestamp) < seconds else { return acc }
                return acc + (e.data["tokens"]?.intValue ?? 0)
            }
        }

        let req1m = countRequests(within: 60)
        let req5m = countRequests(within: 300)
        let req15m = countRequests(within: 900)
        let tok1m = countTokens(within: 60)
        let tok5m = countTokens(within: 300)
        let tok15m = countTokens(within: 900)
        let err5m = events.reduce(0) { acc, e in
            acc + (e.type == .inferenceFailed && now.timeIntervalSince(e.timestamp) < 300 ? 1 : 0)
        }

        return [
            "total_requests": requestCount,
            "total_tokens": tokenCount,
            "total_errors": errorCount,
            "requests_per_min": req1m,
            "load": [
                "req_1m": req1m,
                "req_5m": (Double(req5m) / 5 * 10).rounded() / 10,
                "req_15m": (Double(req15m) / 15 * 10).rounded() / 10,
                "tok_1m": tok1m,
                "tok_5m": Int((Double(tok5m) / 5).rounded()),
                "tok_15m": Int((Double(tok15m) / 15).rounded()),
            ] as [String: Any],
            "requests_5min": req5m,
            "tokens_per_min": tok1m,
            "tokens_5min": tok5m,
            "errors_5min": err5m,
            "tps": tpsLocked(now: now),
            "avg_latency_ms": avgLatencyMsLocked(),
        ]
    }

    /// Sparkline series for one bucket metric over the last `minutes` minutes.
    func sparkline(_ metric: String = "requests", minutes: Int = 30) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        rotateBucketLocked(now: Date())
        return minuteBuckets.suffix(max(0, minutes)).map { $0.value(for: metric) }
    }

    /// Totals for the Prometheus counters, read in one pass under one lock.
    var counters: (requests: Int, tokens: Int, errors: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requestCount, tokenCount, errorCount)
    }

    // MARK: - Subscription (SSE)

    /// An unbounded-in-name-only event stream: the buffering policy drops the
    /// oldest event for a subscriber that can't keep up, matching Python's
    /// `asyncio.Queue(maxsize=200)` + `put_nowait` drop-on-full. A stalled
    /// dashboard tab must never apply backpressure to inference.
    func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(200)) { continuation in
            lock.lock()
            subscribers[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Live subscriber count — exposed for tests and diagnostics.
    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }
}
