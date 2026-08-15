import XCTest
@testable import Mycellm

/// The metered-download guard. Before this existed both download paths ran on
/// `URLSessionConfiguration.default` / `URLSession.shared`, which permit
/// cellular, expensive and constrained access — so a multi-gigabyte model would
/// pull over LTE with nothing in the way.
final class DownloadPolicyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DownloadPolicy.allowExpensiveKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DownloadPolicy.allowExpensiveKey)
        super.tearDown()
    }

    // MARK: - Request stamping

    /// Belt and braces: even if a call site forgets to consult `decide`, the
    /// request itself must not be permitted to spend the user's data.
    func testRequestIsLockedDownByDefault() {
        let r = DownloadPolicy.request(for: URL(string: "https://example.com/m.gguf")!)
        XCTAssertFalse(r.allowsExpensiveNetworkAccess)
        XCTAssertFalse(r.allowsConstrainedNetworkAccess)
        XCTAssertFalse(r.allowsCellularAccess)
    }

    func testPerRequestOverrideOpensItUp() {
        let r = DownloadPolicy.request(for: URL(string: "https://example.com/m.gguf")!, override: true)
        XCTAssertTrue(r.allowsExpensiveNetworkAccess)
        XCTAssertTrue(r.allowsConstrainedNetworkAccess)
        XCTAssertTrue(r.allowsCellularAccess)
    }

    func testStandingPreferenceOpensItUpWithoutAnOverride() {
        UserDefaults.standard.set(true, forKey: DownloadPolicy.allowExpensiveKey)
        let r = DownloadPolicy.request(for: URL(string: "https://example.com/m.gguf")!)
        XCTAssertTrue(r.allowsExpensiveNetworkAccess)
        XCTAssertTrue(r.allowsCellularAccess)
    }

    func testApplyMutatesAnExistingRequestAndPreservesTheRest() {
        var r = URLRequest(url: URL(string: "https://example.com/shard.safetensors")!)
        r.setValue("bytes=100-", forHTTPHeaderField: "Range")
        r.timeoutInterval = 60
        DownloadPolicy.apply(to: &r)

        XCTAssertFalse(r.allowsExpensiveNetworkAccess)
        // The resume header and timeout are what make a 4 GB shard survivable;
        // stamping policy must not disturb them.
        XCTAssertEqual(r.value(forHTTPHeaderField: "Range"), "bytes=100-")
        XCTAssertEqual(r.timeoutInterval, 60)
    }

    // MARK: - Refusal message

    /// The size is the entire reason for refusing out loud instead of failing
    /// silently — a caller (or a person) can only decide with the number.
    func testRefusalMessageCarriesTheSize() {
        let msg = DownloadPolicy.refusalMessage(network: "cellular", bytes: 4_294_967_296)
        XCTAssertTrue(msg.contains("GB"), msg)
        XCTAssertTrue(msg.lowercased().contains("cellular"), msg)
        XCTAssertTrue(msg.contains("allow_expensive"), msg)
    }

    func testRefusalMessageDistinguishesLowDataModeFromCellular() {
        let constrained = DownloadPolicy.refusalMessage(network: "constrained", bytes: 0)
        XCTAssertTrue(constrained.contains("Low Data Mode"), constrained)
        XCTAssertFalse(constrained.lowercased().contains("cellular"), constrained)
    }

    func testRefusalMessageWithUnknownSizeStillReads() {
        let msg = DownloadPolicy.refusalMessage(network: "cellular", bytes: 0)
        XCTAssertFalse(msg.contains("0 bytes"), msg)
        XCTAssertTrue(msg.contains("This model"), msg)
    }

    // MARK: - Decision

    /// Wi-Fi / wired: never refused, whatever the preference says.
    func testUnmeteredIsAlwaysAllowed() {
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: false, isConstrained: false), .allowed)
        UserDefaults.standard.set(true, forKey: DownloadPolicy.allowExpensiveKey)
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: false, isConstrained: false), .allowed)
    }

    /// The branch that costs money if it's wrong, and the one a wired CI box
    /// can never reach through `Connectivity`.
    func testMeteredIsRefusedByDefault() {
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: true, isConstrained: false),
                       .refused(network: "cellular"))
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: false, isConstrained: true),
                       .refused(network: "constrained"))
    }

    /// Cellular wins the label when both are true — "you are on cellular" is
    /// the more actionable of the two for someone reading the refusal.
    func testCellularTakesPrecedenceInTheLabel() {
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: true, isConstrained: true),
                       .refused(network: "cellular"))
    }

    func testPerRequestOverrideBeatsTheDefault() {
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: true, isConstrained: false, override: true),
                       .allowed)
    }

    func testStandingPreferenceAllowsMeteredWithoutAnOverride() {
        UserDefaults.standard.set(true, forKey: DownloadPolicy.allowExpensiveKey)
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: true, isConstrained: false), .allowed)
        XCTAssertEqual(DownloadPolicy.decide(isExpensive: false, isConstrained: true), .allowed)
    }

    func testDecisionIsEquatableAndAllowedIsAllowed() {
        XCTAssertTrue(DownloadPolicy.Decision.allowed.isAllowed)
        XCTAssertFalse(DownloadPolicy.Decision.refused(network: "cellular").isAllowed)
        XCTAssertEqual(DownloadPolicy.Decision.refused(network: "cellular"),
                       .refused(network: "cellular"))
        XCTAssertNotEqual(DownloadPolicy.Decision.refused(network: "cellular"),
                          .refused(network: "constrained"))
    }
}

/// Device fitness — the signals that decide whether this node should be
/// advertising itself as able to serve at all.
final class DeviceStateTests: XCTestCase {

    @MainActor
    private func snapshot() -> DeviceState.Snapshot {
        DeviceState.capture(connectivity: Connectivity())
    }

    @MainActor
    func testSnapshotRendersJSONSerializableBlocks() {
        // A value that can't serialize takes the whole /v1/node/status response
        // down, not just its own block.
        let d = snapshot().asDict
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
        for key in ["thermal", "power", "network", "runtime"] {
            XCTAssertNotNil(d[key], "missing block: \(key)")
        }
    }

    @MainActor
    func testThermalReportsStateAndDerivedFlags() {
        let s = snapshot()
        XCTAssertFalse(s.thermalState.isEmpty)
        // unloading implies throttled — a router that stops at `throttled` must
        // never see a node that is unloading but claims it isn't throttled.
        if s.thermalUnloading { XCTAssertTrue(s.thermalThrottled) }
    }

    func testThermalStateNamesCoverEveryCase() {
        XCTAssertEqual(DeviceState.name(for: .nominal), "nominal")
        XCTAssertEqual(DeviceState.name(for: .fair), "fair")
        XCTAssertEqual(DeviceState.name(for: .serious), "serious")
        XCTAssertEqual(DeviceState.name(for: .critical), "critical")
    }

    @MainActor
    func testPowerNeverReportsANegativeBatteryPercent() {
        // UIKit gives -1 until monitoring is enabled, and -1 serialised as a
        // percentage would read as "critically low" to every scheduler. Absent
        // is correct when unknown; negative never is.
        let s = snapshot()
        if let pct = s.batteryPercent {
            XCTAssertGreaterThanOrEqual(pct, 0)
            XCTAssertLessThanOrEqual(pct, 100)
        }
        let power = s.asDict["power"] as? [String: Any]
        if let pct = power?["battery_percent"] as? Int {
            XCTAssertGreaterThanOrEqual(pct, 0)
        }
    }

    @MainActor
    func testRuntimeAdvertisesTheForegroundRequirement() {
        let runtime = snapshot().asDict["runtime"] as? [String: Any]
        XCTAssertEqual(runtime?["serving_requires_foreground"] as? Bool, true,
                       "iOS suspends a backgrounded node; a fleet has to know")
        XCTAssertNotNil(runtime?["app_state"] as? String)
    }

    @MainActor
    func testNetworkReportsExpensiveAndConstrainedSeparately() {
        // They were previously OR'd into one flag, which threw away the
        // distinction between "this costs money" and "the user asked for less".
        let net = snapshot().asDict["network"] as? [String: Any]
        XCTAssertNotNil(net?["expensive"] as? Bool)
        XCTAssertNotNil(net?["constrained"] as? Bool)
        XCTAssertNotNil(net?["interface"] as? String)
        XCTAssertNotNil(net?["downloads_allowed_on_metered"] as? Bool)
    }

    @MainActor
    func testRoleIsConsumerWithNoModelsRegardlessOfFitness() {
        XCTAssertEqual(DeviceState.effectiveRole(hasLoadedModels: false), "consumer")
    }

    @MainActor
    func testRoleTracksFitnessWhenModelsAreLoaded() {
        // canServe() depends on live device conditions, so assert the invariant
        // rather than a fixed value: a node may only claim `seeder` when it is
        // actually fit to serve.
        let role = DeviceState.effectiveRole(hasLoadedModels: true)
        XCTAssertEqual(role, DeviceState.canServe() ? "seeder" : "consumer")
    }
}
