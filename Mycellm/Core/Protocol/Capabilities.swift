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
    // 4096 is the safe-on-mobile default; actual value gets overwritten
    // from the loaded model's ctx_len when a model is loaded. Capability
    // peers shouldn't assume Python's 32K MYCELLM_DEFAULT_CTX_LEN.
    var ctxLen: Int = 4096
    var backend: String = "llama.cpp"
    var tags: [String] = []
    var tier: String = ""
    var paramCountB: Double = 0.0
    var scope: String = "home"  // "home" | "public" | "networks"
    var visibleNetworks: [String] = []
    var features: [String] = []
    var throughputTokS: Double = 0.0

    // ── 0.8 Adaptive Inference Fabric (additive, optional) ──────────────
    //
    // ⚠️ EVERY ONE OF THESE IS OMITTED FROM `toDict()` WHEN UNSET, AND THAT IS
    // LOAD-BEARING. A 0.7.1 peer — Python or Swift — parses this map with
    // per-key lookups, so it ignores keys it does not know, but only as long as
    // we never *require* one. Emitting `parallelism` on every model would also
    // inflate every announcement on a network where nothing reads it.
    //
    // Mirrors `ModelCapability` in the Python `protocol/capabilities.py`. The
    // two must agree key-for-key: the wire format is the contract, and a
    // divergence here shows up as a peer that is silently ineligible for work
    // rather than as an error anyone sees.

    /// Which deployment serves this model. Empty = served by this peer directly.
    var deploymentId: String = ""
    /// The serving group the deployment belongs to (e.g. an oMLX cluster).
    var servingGroupId: String = ""
    /// {"type": "standalone"|"tensor"|"pipeline"|"external", "world_size": Int}
    var parallelism: [String: CBORValue] = [:]
    /// What this model may be asked to do in a multi-stage job: "direct",
    /// "proposer", "critic", "synthesizer", "verifier", "embed".
    /// Empty means "direct only" — 0.7 semantics.
    var executionRoles: [String] = []

    /// True if this model may be used for `role`.
    ///
    /// Mirrors `ModelCapability.can` on the Python side so both ends answer
    /// identically. Re-deriving this rule at a call site is how the embedding
    /// bug happened — two places disagreed about what a tag meant.
    func can(_ role: String) -> Bool {
        if executionRoles.isEmpty { return role == "direct" }
        return executionRoles.contains(role)
    }

    /// True if a serving group serves this, not this peer's own backend.
    var isGrouped: Bool { !servingGroupId.isEmpty }

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
        // 0.8 fields — emitted only when set, so a 0.7 network sees the
        // byte-identical announcement it saw before.
        if !deploymentId.isEmpty { d["deployment_id"] = .string(deploymentId) }
        if !servingGroupId.isEmpty { d["serving_group_id"] = .string(servingGroupId) }
        if !executionRoles.isEmpty { d["execution_roles"] = .array(executionRoles.map { .string($0) }) }
        if !parallelism.isEmpty { d["parallelism"] = .map(parallelism) }
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
            throughputTokS: d["throughput_tok_s"]?.doubleValue ?? 0.0,
            deploymentId: d["deployment_id"]?.stringValue ?? "",
            servingGroupId: d["serving_group_id"]?.stringValue ?? "",
            parallelism: d["parallelism"]?.mapValue ?? [:],
            executionRoles: d["execution_roles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

/// Hardware description for capability advertisement.
struct HardwareCapability: Sendable {
    var gpu: String = "none"
    var vramGb: Double = 0.0
    var backend: String = "cpu"

    // ── 0.8 additive telemetry ──────────────────────────────────────────
    //
    // ⚠️ THIS NODE ALREADY KNEW ALL OF THIS AND KEPT IT TO ITSELF. `DeviceState`
    // computes thermal, power and network conditions for `/v1/node/status`, and
    // the node already demotes itself to `consumer` when it is in no state to
    // serve — but a peer could only see that demotion, never the reason, and
    // never the softer cases where the node still serves while throttled. A
    // scheduler seeing gpu/vram alone routes to a phone that is at 5% on battery
    // and thermally limited.
    //
    // Nested exactly as Python emits them (`power`/`thermal`/`network` sub-maps),
    // because the wire format is the contract and a peer reads whichever side it
    // came from.
    var ramGb: Double = 0.0
    var availableMemoryGb: Double = 0.0
    var architecture: String = ""
    /// "server" | "desktop" | "laptop" | "mobile"
    var deviceClass: String = ""
    /// Power-limited: Low Power Mode, or low battery while discharging.
    var powerConstrained: Bool = false
    /// Thermally throttled.
    var thermalConstrained: Bool = false
    /// The network costs money (cellular).
    var networkExpensive: Bool = false
    /// The user asked the system to go easy (Low Data Mode).
    var networkConstrained: Bool = false

    /// True when this device should not be handed discretionary work.
    ///
    /// Mirrors `HardwareInfo.is_constrained` on the Python side, which in turn
    /// mirrors the demotion rule this node already applies to itself — so the
    /// device and any scheduler agree about when it is unfit to serve.
    var isConstrained: Bool { powerConstrained || thermalConstrained }

    func toDict() -> [String: CBORValue] {
        var d: [String: CBORValue] = [
            "gpu": .string(gpu),
            "vram_gb": .double(vramGb),
            "backend": .string(backend),
        ]
        // Absent unless set, so a 0.7 network sees an unchanged payload.
        if ramGb > 0 { d["ram_gb"] = .double(ramGb) }
        if availableMemoryGb > 0 { d["available_memory_gb"] = .double(availableMemoryGb) }
        if !architecture.isEmpty { d["architecture"] = .string(architecture) }
        if !deviceClass.isEmpty { d["device_class"] = .string(deviceClass) }
        if powerConstrained { d["power"] = .map(["constrained": .bool(true)]) }
        if thermalConstrained { d["thermal"] = .map(["constrained": .bool(true)]) }
        if networkExpensive || networkConstrained {
            d["network"] = .map([
                "expensive": .bool(networkExpensive),
                "constrained": .bool(networkConstrained),
            ])
        }
        return d
    }

    static func fromDict(_ d: [String: CBORValue]) -> HardwareCapability {
        let power = d["power"]?.mapValue ?? [:]
        let thermal = d["thermal"]?.mapValue ?? [:]
        let network = d["network"]?.mapValue ?? [:]
        return HardwareCapability(
            gpu: d["gpu"]?.stringValue ?? "none",
            vramGb: d["vram_gb"]?.doubleValue ?? 0.0,
            backend: d["backend"]?.stringValue ?? "cpu",
            ramGb: d["ram_gb"]?.doubleValue ?? 0.0,
            availableMemoryGb: d["available_memory_gb"]?.doubleValue ?? 0.0,
            architecture: d["architecture"]?.stringValue ?? "",
            deviceClass: d["device_class"]?.stringValue ?? "",
            powerConstrained: power["constrained"]?.boolValue ?? false,
            thermalConstrained: thermal["constrained"]?.boolValue ?? false,
            networkExpensive: network["expensive"]?.boolValue ?? false,
            networkConstrained: network["constrained"]?.boolValue ?? false
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
