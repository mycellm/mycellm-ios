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

    /// Metered path — cellular, or a personal hotspot. This is the one that
    /// costs the user money.
    ///
    /// ⚠️ KEPT SEPARATE FROM `isConstrained`, WHICH IT USED TO BE OR'D WITH.
    /// They mean different things and warrant different responses: expensive is
    /// "this transfer will appear on a bill", constrained is "the user asked
    /// the system to go easy" (Low Data Mode). A 4 GB model download should be
    /// refused on either, but the message a caller gets — and the decision a
    /// scheduler makes about routing inference here — differ, and collapsing
    /// them threw that away before either could be reported.
    private(set) var isExpensive: Bool = false

    /// Low Data Mode is on for this path.
    private(set) var isConstrained: Bool = false

    /// Coarse interface class: `wifi`, `cellular`, `wired`, `other`, `none`.
    /// Reported on the node API so a fleet can see how a device is attached.
    private(set) var interface: String = "unknown"

    /// True when a large transfer should be held back unless explicitly allowed.
    var isMetered: Bool { isExpensive || isConstrained }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.mycellm.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let iface: String
            if !online {
                iface = "none"
            } else if path.usesInterfaceType(.wifi) {
                iface = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                iface = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                iface = "wired"
            } else {
                iface = "other"
            }
            Task { @MainActor in
                self?.isOnline = online
                self?.isExpensive = expensive
                self?.isConstrained = constrained
                self?.interface = iface
            }
        }
        monitor.start(queue: queue)

        // ⚠️ SEEDED SYNCHRONOUSLY. `pathUpdateHandler` does not fire until the
        // monitor's first evaluation lands, and a download policy that reads
        // "not metered" in that window would wave through exactly the transfer
        // it exists to stop. `currentPath` is populated immediately after
        // `start`, so the first read is already truthful.
        let path = monitor.currentPath
        isOnline = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
    }

    deinit { monitor.cancel() }
}
