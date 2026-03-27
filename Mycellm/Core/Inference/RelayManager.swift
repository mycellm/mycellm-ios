import Foundation

/// Manages relay backends — discovers and registers models from OpenAI-compatible LAN endpoints.
/// Port of the Python RelayManager, simplified for iOS.
@Observable
final class RelayManager: @unchecked Sendable {

    struct RelayEndpoint: Identifiable, Sendable {
        let id = UUID()
        var url: String
        var name: String
        var online: Bool = false
        var error: String = ""
        var models: [String] = []
    }

    private(set) var relays: [RelayEndpoint] = []

    init() {
        loadSaved()
    }

    /// Add a relay backend and discover its models.
    @discardableResult
    func add(url: String, name: String = "") async throws -> RelayEndpoint {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }

        // Check if already added
        if relays.contains(where: { $0.url == normalized }) {
            throw MycellmError.transportError("Relay already added: \(normalized)")
        }

        let label = name.isEmpty ? labelFromURL(normalized) : name
        var relay = RelayEndpoint(url: normalized, name: label)
        relay = await discoverModels(relay)
        relays.append(relay)
        save()

        if !relay.online {
            throw MycellmError.transportError(relay.error.isEmpty ? "Cannot reach \(normalized)" : relay.error)
        }

        return relay
    }

    /// Remove a relay.
    func remove(url: String) {
        relays.removeAll { $0.url == url }
        save()
    }

    /// Refresh models from all relays.
    func refreshAll() async {
        for i in relays.indices {
            relays[i] = await discoverModels(relays[i])
        }
    }

    /// Discover models from a relay's /v1/models endpoint.
    private func discoverModels(_ relay: RelayEndpoint) async -> RelayEndpoint {
        var updated = relay
        guard let url = URL(string: "\(relay.url)/v1/models") else {
            updated.online = false
            updated.error = "Invalid URL"
            return updated
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                updated.online = false
                updated.error = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
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

    // MARK: - Persistence

    private func save() {
        let data = relays.map { ["url": $0.url, "name": $0.name] }
        UserDefaults.standard.set(data, forKey: "relay_backends")
    }

    private func loadSaved() {
        guard let saved = UserDefaults.standard.array(forKey: "relay_backends") as? [[String: String]] else { return }
        relays = saved.map { RelayEndpoint(url: $0["url"] ?? "", name: $0["name"] ?? "") }
        // Discover in background
        Task {
            await refreshAll()
        }
    }
}
