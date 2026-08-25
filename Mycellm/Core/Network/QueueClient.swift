import Foundation

/// Client for a node's async job queue (`/v1/jobs`).
///
/// The queue is where this app's shape and the fleet's shape finally agree. A
/// phone is the *most* intermittent thing on the network and the least able to
/// run a large model, but it is also the device you actually have in your hand
/// when you think of something. Queuing from here and having it run on the Mac
/// Studio tonight is the fleet working the way it should, rather than the
/// phone apologising for not being a workstation.
///
/// ⚠️ NOT PART OF THE CHAT CLIENT, AND NOT STREAMING. A queued job may not
/// start for hours; anything that looks like a chat call would inherit a chat
/// call's timeout and fail the moment the queue does its job.
actor QueueClient {
    private var endpoint: URL?
    private var apiKey: String = ""

    struct Job: Identifiable, Equatable, Sendable {
        let id: String
        let state: String
        let model: String
        let minTier: String
        let prompt: String
        /// Why this job has not started, in the node's words. The field a
        /// user actually reads — a bare "queued" tells them nothing they did
        /// not already know from the absence of an answer.
        let waitingReason: String
        let resultText: String
        let error: String
        let servedBy: String
        let servedModel: String
        let stake: Double
        let createdAt: Double
        let position: Int

        var isTerminal: Bool {
            ["done", "failed", "expired", "cancelled"].contains(state)
        }
    }

    struct Snapshot: Sendable {
        var jobs: [Job] = []
        var counts: [String: Int] = [:]
        /// Device-level reason nothing is starting (Low Power Mode, thermal
        /// throttling, already busy). True even when every job looks fine on
        /// its own, which is exactly when it is hardest to guess.
        var schedulerReason: String = ""
    }

    /// The queue is not enabled on the node, as opposed to unreachable. Worth
    /// its own case because the fixes are completely different — one is a
    /// setting, the other is a network.
    struct Disabled: Error {}

    func configure(endpoint: String, apiKey: String = "") {
        self.endpoint = Self.root(of: endpoint)
        self.apiKey = apiKey
    }

    /// Strip a chat endpoint back to the node root.
    ///
    /// ⚠️ SETTINGS STORES A FULL `…/v1/chat/completions` URL, so the queue's
    /// path has to be derived rather than appended. Getting this wrong 404s
    /// every call, and the symptom — an empty queue — looks exactly like an
    /// empty queue, which is why this is a pure function with tests rather
    /// than three lines inside an actor.
    nonisolated static func root(of endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var url = URL(string: trimmed), url.host != nil else {
            return nil
        }
        // Walk up past /v1/chat/completions (or any deeper path) to the host
        // root. Stopping at "v1" would be wrong: the queue lives at
        // /v1/jobs, so the root must not already contain a version segment.
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// Full URL for a node path. Exposed for tests — the derivation above is
    /// the part that breaks silently.
    nonisolated static func url(root: URL?, path: String) -> URL? {
        guard let root else { return nil }
        var base = root.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    func debugURL(for path: String) -> URL? {
        Self.url(root: endpoint, path: path)
    }

    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = Self.url(root: endpoint, path: path) else {
            throw MycellmError.transportError("No endpoint configured")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MycellmError.transportError("Bad response")
        }
        if http.statusCode == 503,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           err["type"] as? String == "queue_disabled" {
            throw Disabled()
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw MycellmError.transportError(message ?? "HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    /// Queue a job. Returns its id.
    func submit(prompt: String, selection: ModelSelection, stake: Double = 0) async throws -> String {
        var body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
        ]
        // Exactly one of these, never both — the node rejects the
        // contradiction and `ModelSelection` cannot construct it.
        if !selection.wireModel.isEmpty { body["model"] = selection.wireModel }
        if let tier = selection.wireMinTier { body["min_tier"] = tier }
        if stake > 0 { body["stake"] = stake }

        let (data, _) = try await request("/v1/jobs", method: "POST", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["job_id"] as? String else {
            throw MycellmError.transportError("Malformed queue response")
        }
        return id
    }

    func list() async throws -> Snapshot {
        let (data, _) = try await request("/v1/jobs")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Snapshot()
        }
        var snapshot = Snapshot()
        snapshot.counts = (json["counts"] as? [String: Int]) ?? [:]
        snapshot.schedulerReason = ((json["scheduler"] as? [String: Any])?["reason"] as? String) ?? ""
        snapshot.jobs = ((json["jobs"] as? [[String: Any]]) ?? []).compactMap(Self.parse)
        return snapshot
    }

    func cancel(_ jobID: String) async throws {
        _ = try await request("/v1/jobs/\(jobID)", method: "DELETE")
    }

    /// Parse one job row. `nonisolated static` so tests can exercise it
    /// without an actor hop or a live node.
    nonisolated static func parse(_ row: [String: Any]) -> Job? {
        guard let id = row["job_id"] as? String else { return nil }
        let messages = (row["messages"] as? [[String: Any]]) ?? []
        let prompt = messages.last(where: { ($0["role"] as? String) == "user" })
            .flatMap { $0["content"] as? String } ?? ""
        return Job(
            id: id,
            state: row["state"] as? String ?? "queued",
            model: row["model"] as? String ?? "",
            minTier: row["min_tier"] as? String ?? "",
            prompt: prompt,
            waitingReason: row["waiting_reason"] as? String ?? "",
            resultText: row["result_text"] as? String ?? "",
            error: row["error"] as? String ?? "",
            servedBy: row["served_by"] as? String ?? "",
            servedModel: row["served_model"] as? String ?? "",
            stake: row["stake"] as? Double ?? 0,
            createdAt: row["created_at"] as? Double ?? 0,
            position: row["position"] as? Int ?? 0
        )
    }
}
