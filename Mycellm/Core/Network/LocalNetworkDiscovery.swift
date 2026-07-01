import Foundation
import Network
import Observation

/// Browses the LAN for mycellm coordinators advertising `_mycellm._udp`.
///
/// Its first job is a side effect: **starting an NWBrowser is what triggers
/// iOS's Local Network permission prompt.** Without that grant, iOS silently
/// blocks every connection to a LAN IP or `.local` host — so a device can reach
/// the public prime (a public IP) but never a coordinator on the local network. The
/// app declares NSLocalNetworkUsageDescription + NSBonjourServices, but the
/// permission is only requested once a local-network operation actually starts.
///
/// Its second job (phase B) is discovery: surfacing found coordinators so the
/// user can join one without typing an IP.
@Observable
final class LocalNetworkDiscovery: @unchecked Sendable {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        let name: String
    }

    private(set) var found: [Found] = []
    private(set) var isBrowsing = false

    @ObservationIgnored private var browser: NWBrowser?

    /// Start browsing (idempotent). Safe to call whenever the node starts —
    /// this is what surfaces the Local Network permission prompt.
    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_mycellm._udp", domain: nil), using: NWParameters())
        b.stateUpdateHandler = { [weak self] state in
            let browsing: Bool
            if case .ready = state { browsing = true } else { browsing = false }
            Task { @MainActor in self?.isBrowsing = browsing }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names: [Found] = results.compactMap { r in
                if case let .service(name, _, _, _) = r.endpoint { return Found(name: name) }
                return nil
            }
            Task { @MainActor in self?.found = names }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        Task { @MainActor in self.isBrowsing = false }
    }
}
