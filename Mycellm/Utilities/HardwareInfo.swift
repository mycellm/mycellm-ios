import Foundation

/// Device chip and RAM detection for iOS.
enum HardwareInfo {
    /// Total physical memory in bytes.
    static var totalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Total physical memory in GB.
    static var totalMemoryGB: Double {
        Double(totalMemory) / 1_073_741_824.0
    }

    /// Available memory (approximate, from os_proc_available_memory).
    static var availableMemory: UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// Available memory in GB.
    static var availableMemoryGB: Double {
        Double(availableMemory) / 1_073_741_824.0
    }

    /// Device model identifier (e.g., "iPhone16,1").
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0)
            }
        } ?? "unknown"
    }

    /// Human-readable chip name based on model identifier.
    static var chipName: String {
        let model = modelIdentifier
        // Map common identifiers to chip names
        if model.hasPrefix("iPhone16") { return "A17 Pro" }
        if model.hasPrefix("iPhone17") { return "A18" }
        if model.hasPrefix("iPhone15") { return "A16 Bionic" }
        if model.hasPrefix("iPhone14") { return "A15 Bionic" }
        if model.hasPrefix("iPad16") || model.hasPrefix("iPad14,3") || model.hasPrefix("iPad14,4") { return "M4" }
        if model.hasPrefix("iPad14") { return "M2" }
        if model.hasPrefix("iPad13") { return "M1" }
        if model.contains("arm64") { return "Apple Silicon" }
        return "Unknown"
    }

    /// Whether the device has a Neural Engine (A11+).
    static var hasNeuralEngine: Bool { true } // All iOS 17+ devices do

    /// GPU core count (estimate based on chip).
    static var estimatedGPUCores: Int {
        let mem = totalMemoryGB
        if mem >= 16 { return 10 } // iPad Pro M-series
        if mem >= 8 { return 5 }   // Pro iPhones / iPad Air
        return 4                    // Standard iPhones
    }

    /// Maximum model size we should load (60% of physical RAM).
    static var maxModelSizeBytes: UInt64 {
        UInt64(Double(totalMemory) * 0.6)
    }

    /// RAM fit indicator for a model of given size.
    static func ramFit(modelSizeBytes: UInt64) -> RAMFitLevel {
        let ratio = Double(modelSizeBytes) / Double(totalMemory)
        if ratio <= 0.4 { return .comfortable }
        if ratio <= 0.6 { return .tight }
        return .tooLarge
    }

    enum RAMFitLevel: String, Sendable {
        case comfortable  // green — plenty of headroom
        case tight        // yellow — may work but risky
        case tooLarge     // red — will not fit
    }

    /// Build a Capabilities-compatible hardware dict.
    static func capabilitiesHardware() -> HardwareCapability {
        HardwareCapability(
            gpu: chipName,
            vramGb: totalMemoryGB, // iOS unified memory
            backend: "metal"
        )
    }

    /// Build system info payload for /v1/node/system endpoint.
    static func systemInfo() -> [String: CBORValue] {
        [
            "chip": .string(chipName),
            "model": .string(modelIdentifier),
            "total_memory_gb": .double(totalMemoryGB),
            "available_memory_gb": .double(availableMemoryGB),
            "gpu_cores": .int(Int64(estimatedGPUCores)),
            "neural_engine": .bool(hasNeuralEngine),
            "backend": .string("metal"),
            "os": .string("iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"),
        ]
    }
}
