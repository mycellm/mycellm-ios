import XCTest
import SwiftCBOR
@testable import Mycellm

/// 0.8 capability fields, and the compatibility properties they depend on.
///
/// The wire format is the contract between this app and the Python node, and
/// the two are released separately — a phone in the App Store will talk to
/// 0.6.3, 0.7.x and 0.8 nodes at the same time. So the tests that matter here
/// are not "the field round-trips"; they are the ones that pin down the
/// promises a mixed-version fleet relies on:
///
///  1. an unset 0.8 field is ABSENT from the payload, byte-for-byte as 0.7 sent
///  2. an unknown key from a newer peer is ignored, not fatal
///  3. `can()` answers exactly what Python's `ModelCapability.can` answers
final class Capabilities08CompatTests: XCTestCase {

    // MARK: - Additive: unset fields must not appear on the wire

    func testUnsetFieldsAreOmittedSoA07PeerSeesAnUnchangedPayload() {
        let m = ModelCapability(name: "llama3")
        let d = m.toDict()

        // The exact key set a 0.7.1 node emitted for the same model.
        XCTAssertEqual(Set(d.keys), ["name", "quant", "ctx_len", "backend"])
        for key in ["deployment_id", "serving_group_id", "execution_roles", "parallelism"] {
            XCTAssertNil(d[key], "\(key) must be absent when unset")
        }
    }

    func testUnsetHardwareTelemetryIsOmitted() {
        let h = HardwareCapability(gpu: "A17 Pro", vramGb: 8, backend: "metal")
        let d = h.toDict()

        XCTAssertEqual(Set(d.keys), ["gpu", "vram_gb", "backend"])
        for key in ["ram_gb", "architecture", "device_class", "power", "thermal", "network"] {
            XCTAssertNil(d[key], "\(key) must be absent when unset")
        }
    }

    func testSetFieldsAppearWithPythonKeyNames() {
        let m = ModelCapability(
            name: "qwen",
            deploymentId: "grp_aurora/qwen",
            servingGroupId: "grp_aurora",
            parallelism: ["type": .string("external")],
            executionRoles: ["proposer", "synthesizer"]
        )
        let d = m.toDict()

        XCTAssertEqual(d["deployment_id"]?.stringValue, "grp_aurora/qwen")
        XCTAssertEqual(d["serving_group_id"]?.stringValue, "grp_aurora")
        XCTAssertEqual(d["parallelism"]?.mapValue?["type"]?.stringValue, "external")
        XCTAssertEqual(
            d["execution_roles"]?.arrayValue?.compactMap(\.stringValue),
            ["proposer", "synthesizer"])
    }

    // MARK: - Forward compatibility: a newer peer's extra keys

    func testUnknownKeysFromANewerPeerAreIgnoredRatherThanFatal() {
        // This is the property that lets 0.9 ship additive fields without
        // breaking an App Store build that can no longer be changed.
        let fromTheFuture: [String: CBORValue] = [
            "name": .string("future-model"),
            "backend": .string("mlx"),
            "execution_roles": .array([.string("proposer")]),
            "quantum_entangled": .bool(true),
            "cost_per_token": .double(0.0001),
            "nested_unknown": .map(["a": .int(1)]),
        ]
        let m = ModelCapability.fromDict(fromTheFuture)

        XCTAssertEqual(m.name, "future-model")
        XCTAssertEqual(m.backend, "mlx")
        XCTAssertEqual(m.executionRoles, ["proposer"])
    }

    func testA07PayloadDecodesWithZeroValued08Fields() {
        // Exactly what a 0.7.1 node sends. Nothing may be inferred from absence
        // beyond the documented default.
        let legacy: [String: CBORValue] = [
            "name": .string("llama3"),
            "quant": .string("Q4_K_M"),
            "ctx_len": .int(8192),
            "backend": .string("llama.cpp"),
        ]
        let m = ModelCapability.fromDict(legacy)

        XCTAssertEqual(m.deploymentId, "")
        XCTAssertEqual(m.servingGroupId, "")
        XCTAssertTrue(m.parallelism.isEmpty)
        XCTAssertTrue(m.executionRoles.isEmpty)
        XCTAssertFalse(m.isGrouped)
    }

    func testFullRoundTripThroughCBOR() throws {
        let original = Capabilities(
            models: [ModelCapability(
                name: "qwen",
                servingGroupId: "grp_aurora",
                executionRoles: ["proposer"])],
            hardware: HardwareCapability(
                gpu: "A17 Pro", vramGb: 8, backend: "metal",
                ramGb: 8, architecture: "arm64", deviceClass: "mobile",
                thermalConstrained: true, networkExpensive: true),
            role: "seeder")

        let decoded = Capabilities.fromCBORValue(original.toCBORValue())

        XCTAssertEqual(decoded.models.first?.servingGroupId, "grp_aurora")
        XCTAssertEqual(decoded.models.first?.executionRoles, ["proposer"])
        XCTAssertEqual(decoded.hardware.architecture, "arm64")
        XCTAssertEqual(decoded.hardware.deviceClass, "mobile")
        XCTAssertTrue(decoded.hardware.thermalConstrained)
        XCTAssertTrue(decoded.hardware.networkExpensive)
        XCTAssertFalse(decoded.hardware.networkConstrained)
        XCTAssertEqual(decoded.version, NetworkConfig.version)
    }

    // MARK: - Role semantics must match Python exactly

    func testUndeclaredRolesMeansDirectOnly() {
        // Python: `if not self.execution_roles: return role == "direct"`.
        let m = ModelCapability(name: "llama3")
        XCTAssertTrue(m.can("direct"))
        XCTAssertFalse(m.can("proposer"))
        XCTAssertFalse(m.can("synthesizer"))
        XCTAssertFalse(m.can("embed"))
    }

    func testDeclaredRolesAreExactMembership() {
        let m = ModelCapability(name: "qwen", executionRoles: ["proposer", "critic"])
        XCTAssertTrue(m.can("proposer"))
        XCTAssertTrue(m.can("critic"))
        // Declaring any role opts OUT of the ones not named — including direct.
        XCTAssertFalse(m.can("direct"))
        XCTAssertFalse(m.can("synthesizer"))
    }

    func testAnEmbeddingModelDeclaringEmbedCannotBeAskedToGenerate() {
        // The fleet-side half of the embedding fix: a planner reading this
        // excludes the model from every generative role instead of discovering
        // the refusal by being refused.
        let m = ModelCapability(name: "nomic-embed-text", executionRoles: ["embed"])
        XCTAssertTrue(m.can("embed"))
        XCTAssertFalse(m.can("direct"))
        XCTAssertFalse(m.can("proposer"))
        XCTAssertFalse(m.can("synthesizer"))
    }

    // MARK: - Hardware constraint reporting

    func testIsConstrainedCoversPowerAndThermalButNotNetwork() {
        // Mirrors Python's `HardwareInfo.is_constrained`. Network cost is a
        // reason to defer a *download*, not a reason to refuse inference — and
        // conflating the two would take a phone on cellular out of the fleet
        // for work it is perfectly able to do.
        XCTAssertFalse(HardwareCapability().isConstrained)
        XCTAssertTrue(HardwareCapability(powerConstrained: true).isConstrained)
        XCTAssertTrue(HardwareCapability(thermalConstrained: true).isConstrained)
        XCTAssertFalse(HardwareCapability(networkExpensive: true).isConstrained)
        XCTAssertFalse(HardwareCapability(networkConstrained: true).isConstrained)
    }

    func testNetworkBlockCarriesBothFlagsWheneverEitherIsSet() {
        // Python emits the sub-map when either is true and always includes both
        // keys. A decoder that saw only the true one would read the other as
        // false anyway, but the payloads must match so a diff of the two
        // implementations stays empty.
        let d = HardwareCapability(networkConstrained: true).toDict()
        let network = d["network"]?.mapValue
        XCTAssertEqual(network?["expensive"]?.boolValue, false)
        XCTAssertEqual(network?["constrained"]?.boolValue, true)
    }

    func testConstraintSubMapsDecodeFromPythonsNestedShape() {
        let fromPython: [String: CBORValue] = [
            "gpu": .string("RTX 4090"),
            "vram_gb": .double(24),
            "backend": .string("cuda"),
            "ram_gb": .double(64),
            "architecture": .string("x86_64"),
            "device_class": .string("server"),
            "power": .map(["constrained": .bool(true)]),
            "thermal": .map(["constrained": .bool(false)]),
            "network": .map(["expensive": .bool(false), "constrained": .bool(true)]),
        ]
        let h = HardwareCapability.fromDict(fromPython)

        XCTAssertEqual(h.ramGb, 64)
        XCTAssertEqual(h.deviceClass, "server")
        XCTAssertTrue(h.powerConstrained)
        XCTAssertFalse(h.thermalConstrained)
        XCTAssertTrue(h.networkConstrained)
        XCTAssertFalse(h.networkExpensive)
        XCTAssertTrue(h.isConstrained)
    }

    // MARK: - Version parity

    func testCoreVersionIsTheOneTheFleetAdvertises() {
        // A capability advertisement with no explicit version must carry the
        // core parity version, not a placeholder — the whole reason 0.8 fixed
        // the Python side's hardcoded "0.1.0".
        XCTAssertEqual(Capabilities().version, NetworkConfig.version)
        XCTAssertEqual(NetworkConfig.version, "0.8.0")
    }

    func testAPeerAdvertisingNoVersionIsReadAsTheLegacyPlaceholder() {
        // Absence must not be read as "current". A 0.7.x Python node really did
        // send "0.1.0", and a peer that sends nothing is at least that old.
        let c = Capabilities.fromDict(["role": .string("seeder")])
        XCTAssertEqual(c.version, "0.1.0")
    }

    // MARK: - Cross-implementation golden vector

    /// Real CBOR bytes produced by the Python node, decoded here.
    ///
    /// ⚠️ THE OTHER TESTS IN THIS FILE ONLY PROVE SWIFT AGREES WITH ITSELF.
    /// Both implementations were written from the same field list, so a shared
    /// misreading — a key spelled differently, a sub-map flattened, a float
    /// encoded where an int was expected — would pass every round-trip test on
    /// each side and still fail on the wire. This is the byte stream from
    /// `cbor2.dumps(Capabilities.to_dict())` on the Python side, checked in as
    /// a fixture. If either implementation changes the format, this fails.
    ///
    /// Regenerate with (from the Python `app` repo):
    ///   python -c "import base64,cbor2;from mycellm.protocol.capabilities \
    ///     import *; print(base64.b64encode(cbor2.dumps(caps.to_dict())))"
    static let pythonGoldenVector = "p2Ztb2RlbHOCrmRuYW1laXF3ZW4zLTM1YmVxdWFudGZRNF9LX01nY3R4X2xlbhkgAGdiYWNrZW5kY21seGR0YWdzgWRjaGF0ZHRpZXJldGllcjJtcGFyYW1fY291bnRfYvtAQYAAAAAAAGVzY29wZWZwdWJsaWNoZmVhdHVyZXOBaXN0cmVhbWluZ3B0aHJvdWdocHV0X3Rva19z+0BFQAAAAAAAbWRlcGxveW1lbnRfaWR0Z3JwX2F1cm9yYS9xd2VuMy0zNWJwc2VydmluZ19ncm91cF9pZGpncnBfYXVyb3Jhb2V4ZWN1dGlvbl9yb2xlc4JocHJvcG9zZXJrc3ludGhlc2l6ZXJrcGFyYWxsZWxpc22iZHR5cGVoZXh0ZXJuYWxqd29ybGRfc2l6ZQSlZG5hbWVrbm9taWMtZW1iZWRlcXVhbnRgZ2N0eF9sZW4ZEABnYmFja2VuZGlsbGFtYS5jcHBvZXhlY3V0aW9uX3JvbGVzgWVlbWJlZGhoYXJkd2FyZaljZ3B1aFJUWCA0MDkwZ3ZyYW1fZ2L7QDgAAAAAAABnYmFja2VuZGRjdWRhZnJhbV9nYvtAUAAAAAAAAHNhdmFpbGFibGVfbWVtb3J5X2di+0BIAAAAAAAAbGFyY2hpdGVjdHVyZWZ4ODZfNjRsZGV2aWNlX2NsYXNzZnNlcnZlcmVwb3dlcqFrY29uc3RyYWluZWT1Z25ldHdvcmuiaWV4cGVuc2l2ZfRrY29uc3RyYWluZWT1bm1heF9jb25jdXJyZW50CGllc3RfdG9rX3P7QEVAAAAAAABkcm9sZWZzZWVkZXJndmVyc2lvbmUwLjguMGtuZXR3b3JrX2lkc4FobmV0X2hvbWU="

    func testDecodesRealCBORProducedByThePythonNode() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.pythonGoldenVector))
        let cbor = try XCTUnwrap(try? CBOR.decode([UInt8](data)))
        let caps = Capabilities.fromCBORValue(cbor)

        XCTAssertEqual(caps.version, "0.8.0")
        XCTAssertEqual(caps.role, "seeder")
        XCTAssertEqual(caps.maxConcurrent, 8)
        XCTAssertEqual(caps.networkIds, ["net_home"])
        XCTAssertEqual(caps.models.count, 2)

        let qwen = try XCTUnwrap(caps.models.first { $0.name == "qwen3-35b" })
        XCTAssertEqual(qwen.servingGroupId, "grp_aurora")
        XCTAssertEqual(qwen.deploymentId, "grp_aurora/qwen3-35b")
        XCTAssertTrue(qwen.isGrouped)
        XCTAssertEqual(qwen.executionRoles, ["proposer", "synthesizer"])
        XCTAssertEqual(qwen.parallelism["type"]?.stringValue, "external")
        XCTAssertEqual(qwen.parallelism["world_size"]?.intValue, 4)
        XCTAssertEqual(qwen.paramCountB, 35.0)
        XCTAssertTrue(qwen.can("proposer"))
        XCTAssertFalse(qwen.can("direct"))

        let embed = try XCTUnwrap(caps.models.first { $0.name == "nomic-embed" })
        XCTAssertEqual(embed.executionRoles, ["embed"])
        XCTAssertFalse(embed.can("proposer"))

        // Python nests these; a flattened reading would silently produce false.
        XCTAssertEqual(caps.hardware.architecture, "x86_64")
        XCTAssertEqual(caps.hardware.deviceClass, "server")
        XCTAssertEqual(caps.hardware.ramGb, 64.0)
        XCTAssertEqual(caps.hardware.availableMemoryGb, 48.0)
        XCTAssertTrue(caps.hardware.powerConstrained)
        XCTAssertFalse(caps.hardware.thermalConstrained)
        XCTAssertTrue(caps.hardware.networkConstrained)
        XCTAssertFalse(caps.hardware.networkExpensive)
        XCTAssertTrue(caps.hardware.isConstrained)
    }

    /// Emits this implementation's own bytes for the Python suite's fixture.
    ///
    /// Not an assertion — the counterpart lives in
    /// `tests/unit/test_capabilities_08_compat.py`. Run with
    /// `-only-testing:MycellmTests/Capabilities08CompatTests/testEmitSwiftGoldenVector`
    /// and copy the printed base64 when the format changes.
    func testEmitSwiftGoldenVector() throws {
        let caps = Capabilities(
            models: [ModelCapability(
                name: "qwen3-35b", quant: "Q4_K_M", ctxLen: 8192, backend: "mlx",
                tags: ["chat"], tier: "tier2", paramCountB: 35.0, scope: "public",
                features: ["streaming"], throughputTokS: 42.5,
                deploymentId: "grp_aurora/qwen3-35b",
                servingGroupId: "grp_aurora",
                parallelism: ["type": .string("external"), "world_size": .int(4)],
                executionRoles: ["proposer", "synthesizer"])],
            hardware: HardwareCapability(
                gpu: "A17 Pro", vramGb: 8, backend: "metal", ramGb: 8,
                availableMemoryGb: 4, architecture: "arm64", deviceClass: "mobile",
                powerConstrained: true, networkExpensive: true),
            maxConcurrent: 2, estTokS: 12.5, role: "seeder",
            version: NetworkConfig.version, networkIds: ["net_home"])

        let bytes = caps.toCBORValue().encode()
        print("SWIFT_GOLDEN_VECTOR=\(Data(bytes).base64EncodedString())")
        XCTAssertFalse(bytes.isEmpty)
    }
}
