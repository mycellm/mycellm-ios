import Foundation
import UIKit

/// The device conditions that decide whether this node is fit to serve.
///
/// ⚠️ THESE ARE THE FACTS A LINUX NODE DOESN'T HAVE AND A PHONE LIVES BY. A
/// server's answer to "can you take this job" is essentially always yes; a
/// handheld's depends on how hot it is, whether it is on battery, whether the
/// user has put it in Low Power Mode, and whether iOS is about to suspend the
/// process. None of that was visible over the API, so every scheduler in the
/// fleet was routing to iOS nodes on hardware specs alone — the equivalent of
/// picking a server by core count while ignoring that it is on fire.
///
/// Reported additively: the Python node has no counterpart for these blocks and
/// simply won't send them, so consumers test for presence rather than platform.
enum DeviceState {

    /// A captured reading.
    ///
    /// ⚠️ SCALARS, NOT `[String: Any]`. Capturing has to happen on the main
    /// actor (UIKit owns battery and application state) while the API route
    /// that renders it does not, so the value crosses an isolation boundary and
    /// must be `Sendable` — which a dictionary of `Any` cannot be. Holding
    /// typed fields and converting to JSON on the far side keeps the hop legal
    /// without an `@unchecked` promise that would be false.
    struct Snapshot: Sendable {
        // Thermal
        var thermalState: String
        var thermalThrottled: Bool
        var thermalUnloading: Bool
        // Power
        var batteryPercent: Int?
        var batteryState: String
        var charging: Bool
        var lowPowerMode: Bool
        // Network
        var online: Bool
        var interface: String
        var expensive: Bool
        var constrained: Bool
        var meteredDownloadsAllowed: Bool
        // Runtime
        var appState: String
        var foreground: Bool

        /// JSON projection for `/v1/node/status`. Pure — no isolation needed.
        var asDict: [String: Any] {
            var power: [String: Any] = [
                "state": batteryState,
                "charging": charging,
                // Low Power Mode throttles CPU and GPU, so every throughput
                // figure this node advertises is optimistic while it is on.
                "low_power_mode": lowPowerMode,
            ]
            // Only report a percentage we actually have — see `capture`.
            if let batteryPercent { power["battery_percent"] = batteryPercent }

            return [
                "thermal": [
                    "state": thermalState,
                    // `throttled` means throughput is already reduced;
                    // `unloading` means the model is being evicted out from
                    // under in-flight work. A router should stop sending at
                    // `throttled`, not wait for the failure at `critical`.
                    "throttled": thermalThrottled,
                    "unloading": thermalUnloading,
                ] as [String: Any],
                "power": power,
                "network": [
                    "online": online,
                    "interface": interface,
                    // Metered: a bill. Constrained: the user asked the system
                    // to go easy (Low Data Mode). Both suppress large
                    // transfers; reported separately because they differ.
                    "expensive": expensive,
                    "constrained": constrained,
                    "downloads_allowed_on_metered": meteredDownloadsAllowed,
                ] as [String: Any],
                "runtime": [
                    "app_state": appState,
                    // ⚠️ THE SINGLE MOST IMPORTANT iOS FACT FOR A SCHEDULER.
                    // iOS suspends a backgrounded app's networking within
                    // roughly 30 seconds, after which this node stops answering
                    // entirely — not slowly, not with an error, it simply goes
                    // away. A fleet that knows this can drain work beforehand
                    // instead of discovering it as a timeout.
                    "serving_requires_foreground": true,
                    "foreground": foreground,
                ] as [String: Any],
            ]
        }
    }

    @MainActor
    static func capture(connectivity: Connectivity) -> Snapshot {
        // ⚠️ MONITORING MUST BE ENABLED OR THE LEVEL READS -1 FOREVER. UIKit
        // returns -1.0 for `batteryLevel` until `isBatteryMonitoringEnabled` is
        // set, and -1 serialised as a battery percentage is worse than absent:
        // a scheduler comparing `battery_percent < 20` would treat every node
        // as critically low and refuse to route anywhere.
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }

        let level = device.batteryLevel
        let batteryStateName: String
        switch device.batteryState {
        case .charging: batteryStateName = "charging"
        case .full: batteryStateName = "full"
        case .unplugged: batteryStateName = "unplugged"
        default: batteryStateName = "unknown"
        }

        let thermal = ProcessInfo.processInfo.thermalState
        let appState = UIApplication.shared.applicationState

        return Snapshot(
            thermalState: name(for: thermal),
            thermalThrottled: thermal == .serious || thermal == .critical,
            thermalUnloading: thermal == .critical,
            batteryPercent: level >= 0 ? Int((level * 100).rounded()) : nil,
            batteryState: batteryStateName,
            charging: device.batteryState == .charging || device.batteryState == .full,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            online: connectivity.isOnline,
            interface: connectivity.interface,
            expensive: connectivity.isExpensive,
            constrained: connectivity.isConstrained,
            meteredDownloadsAllowed: DownloadPolicy.allowsExpensiveByDefault,
            appState: appState == .active ? "active" : (appState == .inactive ? "inactive" : "background"),
            foreground: appState == .active
        )
    }

    static func name(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: - Fitness

    /// Whether this device should be advertising itself as able to serve.
    ///
    /// ⚠️ THIS DEMOTES THE NODE, IT DOESN'T JUST DESCRIBE IT. Exposing the
    /// signals above and hoping every scheduler reads them correctly is the
    /// weaker half of the idea: a thermally critical phone at 5% on cellular
    /// would still advertise `seeder` and still be handed work, then fail it.
    /// A node is responsible for its own honesty about what it can do.
    @MainActor
    static func canServe() -> Bool {
        if ProcessInfo.processInfo.thermalState == .critical { return false }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        // Below 20% on battery, keep what is left for the person holding it.
        if !charging, level >= 0, level < 0.20 { return false }
        return true
    }

    /// The role to advertise given current conditions. `seeder` claims this node
    /// will serve inference to peers; `consumer` claims only that it participates.
    @MainActor
    static func effectiveRole(hasLoadedModels: Bool) -> String {
        guard hasLoadedModels, canServe() else { return "consumer" }
        return "seeder"
    }

    /// The subset of `Snapshot` that belongs in a capability advertisement.
    ///
    /// ⚠️ NOT THE WHOLE SNAPSHOT, ON PURPOSE. `Snapshot` is the operator view:
    /// battery percentage, app state, interface name. A capability payload goes
    /// to every peer on the network and is retained by each of them, so it
    /// carries only what a scheduler needs to make a routing decision —
    /// "unfit"/"expensive", not "at 7% on Wi-Fi in the background". Broadcasting
    /// a phone's charge level to the fleet is telemetry nobody asked for.
    struct Constraints: Sendable {
        var power: Bool = false
        var thermal: Bool = false
        var networkExpensive: Bool = false
        var networkConstrained: Bool = false
    }

    /// Capture the constraint flags for a capability advertisement.
    ///
    /// The power rule is deliberately the same one `canServe` applies, so the
    /// node cannot advertise "unconstrained" while simultaneously demoting
    /// itself to `consumer` for the same reason.
    @MainActor
    static func capabilityConstraints(connectivity: Connectivity) -> Constraints {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        let lowBattery = !charging && level >= 0 && level < 0.20
        let thermal = ProcessInfo.processInfo.thermalState
        return Constraints(
            power: ProcessInfo.processInfo.isLowPowerModeEnabled || lowBattery,
            // `.serious` is where throughput is already reduced. Waiting for
            // `.critical` means advertising healthy right up to the failure.
            thermal: thermal == .serious || thermal == .critical,
            networkExpensive: connectivity.isExpensive,
            networkConstrained: connectivity.isConstrained
        )
    }
}
