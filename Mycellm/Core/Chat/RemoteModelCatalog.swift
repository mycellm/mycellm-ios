import Foundation
import Observation

/// What the configured endpoint is advertising, loaded once and shared.
///
/// Both places that let you pick a model — the chat bar and Settings — need the
/// same list and the same tier counts. Fetching it in each view would mean two
/// requests, two loading states, and two chances for them to disagree about
/// what "Capable" currently reaches.
/// Main-actor isolated: this is view state, every reader is a SwiftUI view,
/// and `shared` mutable state across actors is exactly what Swift 6 concurrency
/// checking refuses.
@MainActor
@Observable
final class RemoteModelCatalog {
    /// Shared because the chat bar and Settings are both live at once on iPad's
    /// split view, and a model list is not per-view state.
    static let shared = RemoteModelCatalog()

    private(set) var models: [RemoteModel] = []
    private(set) var loading = false
    /// Non-empty when the list is known to be incomplete. Shown rather than
    /// letting a short list read as the whole truth.
    private(set) var error = ""

    private var lastEndpoint = ""
    private var lastLoaded: Date?

    /// Reload if the endpoint changed or the list is older than `maxAge`.
    /// Models come and go as nodes sleep, so a cached list goes stale — but
    /// re-fetching on every keystroke in a picker would be worse.
    func refresh(maxAge: TimeInterval = 60, force: Bool = false) async {
        let endpoint = Preferences.shared.remoteEndpoint
        let stale = lastLoaded.map { Date().timeIntervalSince($0) > maxAge } ?? true
        guard force || stale || endpoint != lastEndpoint else { return }
        guard !loading else { return }

        loading = true
        defer { loading = false }

        let client = RemoteClient()
        await client.configure(endpoint: endpoint, apiKey: Preferences.shared.remoteApiKey)
        do {
            // `auto` is already the Automatic entry in every picker; listing it
            // again as a "specific model" would offer the same thing twice.
            models = try await client.listModelsDetailed().filter { $0.id != "auto" }
            error = models.isEmpty ? "No models advertised by this endpoint." : ""
        } catch {
            models = []
            self.error = "Couldn't reach the endpoint — tier counts unavailable."
        }
        lastEndpoint = endpoint
        lastLoaded = Date()
    }
}
