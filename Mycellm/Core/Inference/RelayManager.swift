import Foundation

/// Manages relay backends — discovers and registers models from OpenAI-compatible LAN endpoints.
/// Port of the Python RelayManager with api_key, max_concurrent, and background polling.
@Observable
final class RelayManager: @unchecked Sendable {

    struct RelayEndpoint: Identifiable, Sendable {
        let id = UUID()
        var url: String
        var name: String
        var apiKey: String = ""
        var maxConcurrent: Int = 32
        var online: Bool = false
        var error: String = ""
        var models: [String] = []
    }

    private(set) var relays: [RelayEndpoint] = []
    private var pollTask: Task<Void, Never>?
    private var pollInterval: TimeInterval = 60

    init() {
        loadSaved()
    }

    // MARK: - CRUD

    @discardableResult
    func add(url: String, name: String = "", apiKey: String = "", maxConcurrent: Int = 32) async throws -> RelayEndpoint {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }

        if relays.contains(where: { $0.url == normalized }) {
            throw MycellmError.transportError("Relay already added: \(normalized)")
        }

        let label = name.isEmpty ? labelFromURL(normalized) : name
        var relay = RelayEndpoint(url: normalized, name: label, apiKey: apiKey, maxConcurrent: maxConcurrent)
        relay = await discoverModels(relay)
        relays.append(relay)
        save()

        if !relay.online {
            throw MycellmError.transportError(relay.error.isEmpty ? "Cannot reach \(normalized)" : relay.error)
        }

        return relay
    }

    func remove(url: String) {
        relays.removeAll { $0.url == url }
        save()
    }

    // MARK: - Refresh

    func refreshAll() async {
        for i in relays.indices {
            relays[i] = await discoverModels(relays[i])
        }
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 60) {
        pollInterval = interval
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 60))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Discovery

    private func discoverModels(_ relay: RelayEndpoint) async -> RelayEndpoint {
        var updated = relay
        guard let url = URL(string: "\(relay.url)/v1/models") else {
            updated.online = false
            updated.error = "Invalid URL"
            return updated
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !relay.apiKey.isEmpty {
            request.setValue("Bearer \(relay.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                updated.online = false
                updated.error = "No response"
                return updated
            }

            if http.statusCode == 401 {
                updated.online = false
                updated.error = "Authentication failed (401)"
                return updated
            }

            guard http.statusCode == 200 else {
                updated.online = false
                updated.error = "HTTP \(http.statusCode)"
                return updated
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                updated.models = models.compactMap { $0["id"] as? String }
                updated.online = true
                updated.error = ""
            } else {
                updated.online = false
                updated.error = "Invalid response"
            }
        } catch {
            updated.online = false
            updated.error = error.localizedDescription
        }

        return updated
    }

    private func labelFromURL(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return "relay" }
        if host == "localhost" || host == "127.0.0.1" {
            return "localhost:\(parsed.port ?? 80)"
        }
        return host.components(separatedBy: ".").first ?? host
    }

    // MARK: - Status (for REST API)

    func status() -> [[String: Any]] {
        relays.map { r in
            [
                "url": r.url,
                "name": r.name,
                "online": r.online,
                "error": r.error,
                "models": r.models,
                "model_count": r.models.count,
            ] as [String: Any]
        }
    }

    // MARK: - Persistence

    private func save() {
        let data: [[String: Any]] = relays.map {
            ["url": $0.url, "name": $0.name, "api_key": $0.apiKey, "max_concurrent": $0.maxConcurrent]
        }
        UserDefaults.standard.set(data, forKey: "relay_backends")
    }

    private func loadSaved() {
        guard let saved = UserDefaults.standard.array(forKey: "relay_backends") as? [[String: Any]] else { return }
        relays = saved.map {
            RelayEndpoint(
                url: $0["url"] as? String ?? "",
                name: $0["name"] as? String ?? "",
                apiKey: $0["api_key"] as? String ?? "",
                maxConcurrent: $0["max_concurrent"] as? Int ?? 32
            )
        }
        Task { await refreshAll() }
    }
}
