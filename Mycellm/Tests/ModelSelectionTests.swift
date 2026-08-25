import XCTest
@testable import Mycellm

/// `ModelSelection` — one value that cannot express a contradiction.
///
/// The property under test throughout: a tier floor and a named model are
/// mutually exclusive, because a floor constrains the node's *choice* and a
/// named model leaves nothing to choose. The node rejects a request carrying
/// both; this type makes such a request unrepresentable on the client, which
/// is a stronger guarantee than remembering not to build one.
final class ModelSelectionTests: XCTestCase {

    // MARK: - Round-tripping the stored preference

    func testEmptyStringIsAutomatic() {
        XCTAssertEqual(ModelSelection(stored: ""), .auto)
    }

    func testLegacyAutoValuesAreAutomatic() {
        // Earlier builds wrote "default" on the wire and could store "auto".
        // Both must decode to Automatic rather than to a model nobody serves.
        XCTAssertEqual(ModelSelection(stored: "auto"), .auto)
        XCTAssertEqual(ModelSelection(stored: "default"), .auto)
        XCTAssertEqual(ModelSelection(stored: "   "), .auto)
    }

    func testExistingModelNamesStillDecode() {
        // The preference key is shared with previous releases: an install
        // upgrading with "qwen3-9b" saved must keep using qwen3-9b.
        XCTAssertEqual(ModelSelection(stored: "qwen3-9b"), .model("qwen3-9b"))
    }

    func testTierRoundTrips() {
        for tier in ModelSelection.Tier.allCases {
            let stored = ModelSelection.tier(tier).stored
            XCTAssertEqual(ModelSelection(stored: stored), .tier(tier))
        }
    }

    func testUnknownTierNameDecodesAsAModel() {
        // Not a crash and not silently Automatic: if a future build writes a
        // tier this one does not know, treating it as a model name means the
        // node answers with a clear "no node is serving that" instead of this
        // app quietly ignoring the user's choice.
        XCTAssertEqual(ModelSelection(stored: "tier:enormous"), .model("tier:enormous"))
    }

    // MARK: - What goes on the wire

    func testAutomaticSendsNeitherField() {
        let s = ModelSelection.auto
        XCTAssertEqual(s.wireModel, "")
        XCTAssertNil(s.wireMinTier)
    }

    func testTierSendsAFloorAndAnEmptyModel() {
        let s = ModelSelection.tier(.capable)
        XCTAssertEqual(s.wireModel, "", "a floor is meaningless unless the node is choosing")
        XCTAssertEqual(s.wireMinTier, "capable")
    }

    func testModelSendsNoFloor() {
        let s = ModelSelection.model("qwen3-9b")
        XCTAssertEqual(s.wireModel, "qwen3-9b")
        XCTAssertNil(s.wireMinTier, "the node rejects model + min_tier together")
    }

    func testNoSelectionEverSendsBoth() {
        let all: [ModelSelection] = [.auto, .model("m"), .model("mycellm/swarm")]
            + ModelSelection.Tier.allCases.map { .tier($0) }
        for s in all {
            XCTAssertFalse(!s.wireModel.isEmpty && s.wireMinTier != nil,
                           "\(s) would send a contradictory request")
        }
    }

    func testSwarmIsJustAModelName() {
        // `mycellm/swarm` selects a strategy, but on the wire it travels in
        // the model field like any other name.
        let s = ModelSelection(stored: "mycellm/swarm")
        XCTAssertEqual(s.wireModel, "mycellm/swarm")
        XCTAssertNil(s.wireMinTier)
    }

    func testIsResolvingIsTrueExactlyWhenTheNodeChooses() {
        XCTAssertTrue(ModelSelection.auto.isResolving)
        XCTAssertTrue(ModelSelection.tier(.fast).isResolving)
        XCTAssertFalse(ModelSelection.model("qwen3-9b").isResolving)
    }

    // MARK: - Labels

    func testLabelsAreHumanReadable() {
        XCTAssertEqual(ModelSelection.auto.label, "Automatic")
        XCTAssertEqual(ModelSelection.tier(.frontier).label, "Frontier (65B+)")
        XCTAssertEqual(ModelSelection.model("qwen3-9b").label, "qwen3-9b")
    }

    func testLabelNeverLeaksTheWireEncoding() {
        // The chat header renders this; showing "tier:capable" there was the
        // bug this check exists to prevent.
        XCTAssertFalse(ModelSelection(stored: "tier:capable").label.contains("tier:"))
    }

    // MARK: - Tier boundaries

    func testTierBoundariesMatchTheServer() {
        // Mirrors router/model_resolver.TIER_THRESHOLDS. If these drift, a
        // phone and a node disagree about what "capable" means and the counts
        // shown next to each tier become lies.
        XCTAssertEqual(ModelSelection.Tier.forParams(0.5), .tiny)
        XCTAssertEqual(ModelSelection.Tier.forParams(2.9), .tiny)
        XCTAssertEqual(ModelSelection.Tier.forParams(3.0), .fast)
        XCTAssertEqual(ModelSelection.Tier.forParams(12.9), .fast)
        XCTAssertEqual(ModelSelection.Tier.forParams(13.0), .capable)
        XCTAssertEqual(ModelSelection.Tier.forParams(64.9), .capable)
        XCTAssertEqual(ModelSelection.Tier.forParams(65.0), .frontier)
    }

    // MARK: - Availability counting

    func testCountAtTierIncludesEverythingAbove() {
        // A floor admits its own tier and better. Counting only exact matches
        // would show "Capable — 0" on a fleet whose only model is a 70B.
        let models = [
            RemoteModel(id: "a", tierName: "tiny"),
            RemoteModel(id: "b", tierName: "capable"),
            RemoteModel(id: "c", tierName: "frontier"),
        ]
        XCTAssertEqual(models.count(atLeast: .tiny), 3)
        XCTAssertEqual(models.count(atLeast: .capable), 2)
        XCTAssertEqual(models.count(atLeast: .frontier), 1)
    }

    func testModelsWithoutATierNeverCount() {
        // A 0.7 node sends no tier. Unknown must mean unknown: counting it
        // toward Frontier would promise a route the resolver then refuses.
        let models = [RemoteModel(id: "mystery", tierName: nil)]
        XCTAssertEqual(models.count(atLeast: .frontier), 0)
        XCTAssertEqual(models.count(atLeast: .tiny), 0)
    }

    func testRemoteModelIgnoresAnUnknownTierName() {
        XCTAssertNil(RemoteModel(id: "x", tierName: "enormous").tier)
    }
}
