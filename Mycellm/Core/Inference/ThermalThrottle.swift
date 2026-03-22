import Foundation
import Observation

/// Monitors ProcessInfo.thermalState and adjusts inference behavior.
@Observable
final class ThermalThrottle: @unchecked Sendable {
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var shouldThrottle = false
    private(set) var shouldUnload = false

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        updateFlags()

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
            self?.updateFlags()
        }
    }

    private func updateFlags() {
        switch thermalState {
        case .nominal, .fair:
            shouldThrottle = false
            shouldUnload = false
        case .serious:
            shouldThrottle = true
            shouldUnload = false
        case .critical:
            shouldThrottle = true
            shouldUnload = true
        @unknown default:
            shouldThrottle = false
            shouldUnload = false
        }
    }

    var stateDescription: String {
        switch thermalState {
        case .nominal: "Normal"
        case .fair: "Slightly Elevated"
        case .serious: "High — Throttling"
        case .critical: "Critical — Unloading"
        @unknown default: "Unknown"
        }
    }

    var stateColor: String {
        switch thermalState {
        case .nominal: "sporeGreen"
        case .fair: "ledgerGold"
        case .serious: "computeRed"
        case .critical: "poisonPurple"
        @unknown default: "consoleText"
        }
    }
}
