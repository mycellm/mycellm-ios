import Foundation
import Network
import Observation

/// Device-level internet reachability via NWPathMonitor.
///
/// Distinct from `NodeConnection.bootstrapState`: a device can be online but
/// not yet connected to a mycellm bootstrap, or offline entirely. Views use
/// this to dim/explain network-only affordances (e.g. the Chat "Network"
/// route) and steer users toward on-device inference when offline.
@Observable
final class Connectivity: @unchecked Sendable {
    /// True when the device has a usable network path. Optimistic default so
    /// the UI doesn't flash "offline" before the first path update arrives.
    private(set) var isOnline: Bool = true
    /// Path is cellular/hotspot (expensive) or Low Data Mode (constrained).
    private(set) var isConstrained: Bool = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.mycellm.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let constrained = path.isExpensive || path.isConstrained
            Task { @MainActor in
                self?.isOnline = online
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
