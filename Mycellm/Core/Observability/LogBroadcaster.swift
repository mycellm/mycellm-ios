import Foundation
import os

/// Recent log lines plus a live fan-out, behind `/v1/node/logs` and
/// `/v1/node/logs/stream`. Mirrors `LogBroadcaster` in `src/mycellm/node.py`.
///
/// ⚠️ THIS IS A SINK, NOT A TAP. The Python broadcaster is a `logging.Handler`
/// installed on the root logger, so it captures everything the daemon logs for
/// free. Apple's unified logging has no equivalent hook — `OSLog` is write-only
/// from inside the process, and reading it back requires `OSLogStore`, which on
/// iOS returns only this process's entries with a privacy-redacted payload and a
/// multi-second query cost per scrape. A dashboard polling `/v1/node/logs` every
/// few seconds cannot pay that. So call sites log *here* and this forwards to
/// `os.Logger` on the way through, rather than the reverse. Anything logged only
/// via `os_log`/`print` is invisible to the endpoint by design.
final class LogBroadcaster: @unchecked Sendable {

    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    /// One line, already in wire form. Python emits exactly these four keys.
    struct Entry: Sendable {
        let time: String
        let level: Level
        let name: String
        let message: String

        var asDict: [String: Any] {
            ["time": time, "level": level.rawValue, "name": name, "message": message]
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let maxLen: Int
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var subscribers: [UUID: AsyncStream<Entry>.Continuation] = [:]

    /// Shared instance — call sites reach it directly, the way they would a
    /// module-level logger.
    static let shared = LogBroadcaster()

    init(maxLen: Int = 200) {
        self.maxLen = maxLen
    }

    // MARK: - Emitting

    func log(_ level: Level, _ name: String, _ message: String, at date: Date = Date()) {
        let entry = Entry(
            time: Self.clockFormatter.string(from: date),
            level: level, name: name, message: message
        )

        lock.lock()
        buffer.append(entry)
        if buffer.count > maxLen { buffer.removeFirst(buffer.count - maxLen) }
        let targets = Array(subscribers.values)
        lock.unlock()

        // Yield outside the lock — see ActivityTracker.record for why.
        for continuation in targets { continuation.yield(entry) }

        // Mirror to the system log so Console.app and sysdiagnose keep working;
        // the message is already a formed string, so interpolation is public.
        let logger = os.Logger(subsystem: "com.mycellm.app", category: name)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    func debug(_ name: String, _ message: String) { log(.debug, name, message) }
    func info(_ name: String, _ message: String) { log(.info, name, message) }
    func warning(_ name: String, _ message: String) { log(.warning, name, message) }
    func error(_ name: String, _ message: String) { log(.error, name, message) }

    // MARK: - Reads

    /// The last `limit` entries, oldest first.
    func recent(limit: Int = 100) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.suffix(max(0, limit)).map(\.asDict)
    }

    // MARK: - Subscription (SSE)

    func subscribe() -> AsyncStream<Entry> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
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

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }
}
