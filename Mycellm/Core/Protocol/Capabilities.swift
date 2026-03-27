import Foundation
import SwiftCBOR

/// Model tier boundaries (by parameter count in billions).
enum ModelTier: String, Sendable {
    case tier1 = "tier1"  // ≤8B — Standard
    case tier2 = "tier2"  // ≤70B — Large
    case tier3 = "tier3"  // >70B — Frontier

    static func classify(paramCountB: Double) -> ModelTier {
        if paramCountB <= 0 { return .tier1 }
        if paramCountB <= 8.0 { return .tier1 }
        if paramCountB <= 70.0 { return .tier2 }
        return .tier3
    }

    var displayName: String {
        switch self {
        case .tier1: "Standard (≤8B)"
        case .tier2: "Large (≤70B)"
        case .tier3: "Frontier (>70B)"
        }
    }
}

/// A model this node can serve.
struct ModelCapability: Sendable {
    var name: String
    var quant: String = ""
    var ctxLen: Int = 4096
    var backend: String = "llama.cpp"
    var tags: [String] = []
    var tier: String = ""
    var paramCountB: Double = 0.0
    var scope: String = "home"  // "home" | "public" | "networks"
    var visibleNetworks: [String] = []
    var features: [String] = []
    var throughputTokS: Double = 0.0

    func toDict() -> [String: CBORValue] {
        var d: [String: CBORValue] = [
            "name": .string(name),
            "quant": .string(quant),
            "ctx_len": .int(Int64(ctxLen)),
            "backend": .string(backend),
        ]
        if !tags.isEmpty { d["tags"] = .array(tags.map { .string($0) }) }
        if !tier.isEmpty { d["tier"] = .string(tier) }
        if paramCountB > 0 { d["param_count_b"] = .double(paramCountB) }
        if scope != "home" { d["scope"] = .string(scope) }
        if !visibleNetworks.isEmpty { d["visible_networks"] = .array(visibleNetworks.map { .string($0) }) }
        if !features.isEmpty { d["features"] = .array(features.map { .string($0) }) }
        if throughputTokS > 0 { d["throughput_tok_s"] = .double(throughputTokS) }
        return d
    }

    static func fromDict(_ d: [String: CBORValue]) -> ModelCapability {
        ModelCapability(
            name: d["name"]?.stringValue ?? "",
            quant: d["quant"]?.stringValue ?? "",
            ctxLen: d["ctx_len"]?.intValue ?? 4096,
            backend: d["backend"]?.stringValue ?? "llama.cpp",
            tags: d["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            tier: d["tier"]?.stringValue ?? "",
            paramCountB: d["param_count_b"]?.doubleValue ?? 0.0,
            scope: d["scope"]?.stringValue ?? "home",
            visibleNetworks: d["visible_networks"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            features: d["features"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            throughputTokS: d["throughput_tok_s"]?.doubleValue ?? 0.0
        )
    }
}

/// Hardware description for capability advertisement.
struct HardwareCapability: Sendable {
    var gpu: String = "none"
    var vramGb: Double = 0.0
    var backend: String = "cpu"

    func toDict() -> [String: CBORValue] {
        ["gpu": .string(gpu), "vram_gb": .double(vramGb), "backend": .string(backend)]
    }

    static func fromDict(_ d: [String: CBORValue]) -> HardwareCapability {
        HardwareCapability(
            gpu: d["gpu"]?.stringValue ?? "none",
            vramGb: d["vram_gb"]?.doubleValue ?? 0.0,
            backend: d["backend"]?.stringValue ?? "cpu"
        )
    }
}

/// Full capability advertisement for a node.
struct Capabilities: Sendable {
    var models: [ModelCapability] = []
    var hardware: HardwareCapability = HardwareCapability()
    var maxConcurrent: Int = 2
    var estTokS: Double = 0.0
    var role: String = "seeder"
    var version: String = NetworkConfig.version
    var networkIds: [String] = []

    func toDict() -> [String: CBORValue] {
        var d: [String: CBORValue] = [
            "models": .array(models.map { .map($0.toDict()) }),
            "hardware": .map(hardware.toDict()),
            "max_concurrent": .int(Int64(maxConcurrent)),
            "est_tok_s": .double(estTokS),
            "role": .string(role),
            "version": .string(version),
        ]
        if !networkIds.isEmpty {
            d["network_ids"] = .array(networkIds.map { .string($0) })
        }
        return d
    }

    func toCBORValue() -> CBOR {
        toDict().toCBOR()
    }

    static func fromDict(_ d: [String: CBORValue]) -> Capabilities {
        let models = d["models"]?.arrayValue?.compactMap { v -> ModelCapability? in
            guard let m = v.mapValue else { return nil }
            return ModelCapability.fromDict(m)
        } ?? []

        let hardware = d["hardware"]?.mapValue.map { HardwareCapability.fromDict($0) } ?? HardwareCapability()

        return Capabilities(
            models: models,
            hardware: hardware,
            maxConcurrent: d["max_concurrent"]?.intValue ?? 2,
            estTokS: d["est_tok_s"]?.doubleValue ?? 0.0,
            role: d["role"]?.stringValue ?? "seeder",
            version: d["version"]?.stringValue ?? "0.1.0",
            networkIds: d["network_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    static func fromCBORValue(_ cbor: CBOR) -> Capabilities {
        let dict = cbor.toDictionary()
        return fromDict(dict)
    }
}
