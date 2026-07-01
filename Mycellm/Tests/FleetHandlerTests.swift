import XCTest
@testable import Mycellm

/// F1-P1 fleet-command auth gate. Command dispatch needs a live NodeService
/// (covered by integration/manual testing); these cover the security-critical
/// admin-key gate, which returns before any NodeService access.
final class FleetHandlerTests: XCTestCase {

    func testRejectsWhenNoKeyConfigured() async {
        let handler = FleetHandler()
        let (ok, _, error) = await handler.handle(command: "node.status", params: [:], adminKey: "anything")
        XCTAssertFalse(ok)
        XCTAssertEqual(error, "Fleet admin key not configured on this node")
    }

    func testRejectsWrongKey() async {
        let handler = FleetHandler()
        await handler.setFleetKey("s3cret")
        let (ok, _, error) = await handler.handle(command: "node.status", params: [:], adminKey: "wrong")
        XCTAssertFalse(ok)
        XCTAssertEqual(error, ErrorCode.fleetKeyDenied.rawValue)
    }

    func testCorrectKeyPassesGate() async {
        // Right key, but no NodeService wired → proves the gate passed and the
        // command reached dispatch (which then reports the missing service).
        let handler = FleetHandler()
        await handler.setFleetKey("s3cret")
        let (ok, _, error) = await handler.handle(command: "node.status", params: [:], adminKey: "s3cret")
        XCTAssertFalse(ok)
        XCTAssertEqual(error, "node_service_unavailable")
    }

    func testIsEnabledReflectsKey() async {
        let handler = FleetHandler()
        var enabled = await handler.isEnabled
        XCTAssertFalse(enabled)
        await handler.setFleetKey("")
        enabled = await handler.isEnabled
        XCTAssertFalse(enabled, "Empty key must not enable fleet control")
        await handler.setFleetKey("k")
        enabled = await handler.isEnabled
        XCTAssertTrue(enabled)
    }

    // MARK: - Constant-time compare

    func testConstantTimeEqual() {
        XCTAssertTrue(FleetHandler.constantTimeEqual("abc123", "abc123"))
        XCTAssertFalse(FleetHandler.constantTimeEqual("abc123", "abc124"))
        XCTAssertFalse(FleetHandler.constantTimeEqual("abc", "abc123"))   // length differs
        XCTAssertFalse(FleetHandler.constantTimeEqual("abc123", "abc"))   // length differs
        XCTAssertTrue(FleetHandler.constantTimeEqual("", ""))
        XCTAssertFalse(FleetHandler.constantTimeEqual("", "x"))
        XCTAssertFalse(FleetHandler.constantTimeEqual("x", ""))   // empty RHS must not crash
        XCTAssertTrue(FleetHandler.constantTimeEqual("🔑emoji", "🔑emoji")) // multibyte
    }
}
