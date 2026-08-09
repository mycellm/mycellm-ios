import Foundation
import Hummingbird
import NIOCore

/// Authentication for the node's management API — parity with the Python node.
///
/// ⚠️ EVERY MANAGEMENT ENDPOINT WAS OPEN. `/v1/node/models/load`,
/// `/delete-file`, `/remove-config`, `/relay/add` and the rest mutate the device
/// and required no credential at all, on a port published to the local network
/// with Bonjour. Anyone on the same café Wi-Fi could unload a model, delete
/// several gigabytes of weights, or re-point a relay. The chat endpoint being
/// open is the design; the management surface being open was an oversight.
///
/// The rules are lifted from `mycellm/api/app.py` so a caller written against
/// one node works against the other:
///
///   * three accepted locations, any one is enough —
///       `Authorization: Bearer <key>`, `X-API-Key: <key>`, `?api_key=<key>`
///   * constant-time comparison
///   * `/health` and the inference paths stay public (this is a NODE; being
///     usable by strangers is the entire point)
///   * everything under `/v1/node/**` requires a key
///   * escalating per-IP lockout after repeated failures
///
/// ⚠️ A VALID KEY IS CHECKED BEFORE THE LOCKOUT, and that ordering is load-
/// bearing — the Python side records why: a keyless poller sharing an IP with an
/// authenticated client (localhost, most obviously) could otherwise lock out the
/// authenticated caller and make the node look wedged to its own watchdog.
///
/// ⚠️ PLATFORM DIFFERENCE, DELIBERATE. The Python node has one `settings.api_key`.
/// An iOS node also belongs to networks, and a network may carry a `fleetKey`
/// described in `NetworkMembership` as the opt-in remote-management credential —
/// so that is accepted too, and only from memberships that are enabled. A
/// network's `joinKey` is NOT accepted: joining is not administering, and a join
/// credential is by nature handed around.
struct NodeAuth: Sendable {

    /// Public in the Python sense: no key required, ever.
    private static let publicPaths: Set<String> = [
        "/health", "/v1/models", "/v1/models/capabilities",
        "/v1/chat/completions", "/v1/completions", "/v1/embeddings",
    ]

    /// Only the management surface is gated.
    private static let protectedPrefixes = ["/v1/node/"]

    static func isProtected(_ path: String) -> Bool {
        if publicPaths.contains(path) { return false }
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    /// Every credential this device is willing to be managed with.
    ///
    /// Read fresh per request rather than captured at boot: a user who rotates
    /// the key in Settings expects the old one to stop working immediately, and
    /// a fleet key added by joining a network should work without a restart.
    /// ⚠️ READS UserDefaults DIRECTLY, NOT `Preferences.shared`. Hummingbird
    /// handlers are non-isolated and `Preferences` is @MainActor — the load
    /// handler in HTTPServer already carries this note. Hopping to the main
    /// actor to authenticate every request would also put the UI thread on the
    /// critical path of an inference API.
    static func acceptedKeys(registry: NetworkRegistry?) -> [String] {
        var keys: [String] = []
        let local = UserDefaults.standard.string(forKey: "api_key") ?? ""
        if !local.isEmpty { keys.append(local) }
        for m in registry?.memberships ?? [] where m.enabled {
            if let fleet = m.fleetKey, !fleet.isEmpty { keys.append(fleet) }
        }
        return keys
    }

    /// ⚠️ NOT `==`. String equality on Swift returns as soon as two bytes differ,
    /// which leaks the length of the matching prefix to anyone able to time it.
    /// Over a LAN that is a marginal attack, but the mitigation costs nothing and
    /// the Python side already does it (`hmac.compare_digest`).
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    static func presentedKey(_ request: Request) -> String? {
        if let auth = request.headers[.authorization], auth.hasPrefix("Bearer ") {
            return String(auth.dropFirst(7))
        }
        if let header = request.headers[values: .init("X-API-Key")!].first {
            return header
        }
        return request.uri.queryParameters.get("api_key").map { String($0) }
    }
}

/// Escalating per-IP lockout, matching the Python node's ladder.
///
/// ⚠️ An actor, not a dictionary behind a lock. Hummingbird handlers are
/// non-isolated and run concurrently; a plain mutable dictionary here is a data
/// race that shows up as a crash under exactly the condition this exists to
/// handle — many requests at once.
actor AuthLockout {
    static let shared = AuthLockout()

    /// failures → seconds locked. Same shape as the Python ladder.
    private static let ladder: [(attempts: Int, lockout: TimeInterval)] =
        [(5, 30), (10, 300), (20, 3600)]

    private var failures: [String: Int] = [:]
    private var lockedUntil: [String: Date] = [:]

    func lockRemaining(_ ip: String) -> Int? {
        guard let until = lockedUntil[ip], until > Date() else { return nil }
        return Int(until.timeIntervalSinceNow.rounded(.up))
    }

    func recordFailure(_ ip: String) {
        let n = (failures[ip] ?? 0) + 1
        failures[ip] = n
        for step in Self.ladder.reversed() where n >= step.attempts {
            lockedUntil[ip] = Date().addingTimeInterval(step.lockout)
            return
        }
    }

    func clear(_ ip: String) {
        failures.removeValue(forKey: ip)
        lockedUntil.removeValue(forKey: ip)
    }
}

/// Request context that carries the peer address.
///
/// ⚠️ THE DEFAULT `BasicRequestContext` DOES NOT CARRY ONE, and nothing in
/// Hummingbird conforms to `RemoteAddressRequestContext` for you — its own
/// TracingMiddleware reaches the address through an `as?` cast that, with the
/// default context, simply returns nil forever. Had the middleware below done
/// the same, every request would have looked like it came from "unknown": one
/// shared lockout bucket for the whole network (any stranger could lock out the
/// owner) and a loopback exemption that never fires. Hence a concrete context
/// and a `RemoteAddressRequestContext` constraint on the middleware — if this
/// type is ever swapped for one without an address, it fails to compile instead
/// of quietly degrading.
struct NodeRequestContext: RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}

/// Hummingbird middleware applying the above.
struct NodeAuthMiddleware<Context: RemoteAddressRequestContext>: RouterMiddleware {
    /// The registry is held, not looked up: memberships live on NodeService and
    /// there is no global. Weak would be wrong — the middleware lives exactly as
    /// long as the server, which lives as long as the service.
    let registry: NetworkRegistry?

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard NodeAuth.isProtected(path) else {
            return try await next(request, context)
        }

        let ip = context.remoteAddress?.ipAddress ?? "unknown"
        let keys = NodeAuth.acceptedKeys(registry: registry)

        // ⚠️ NO KEY SET MEANS NO REMOTE MANAGEMENT — it does NOT mean open house.
        // A fresh install has an empty api_key, and treating "unconfigured" as
        // "unauthenticated is fine" is how the current hole would quietly
        // survive this change. Loopback keeps working so the device can always
        // manage itself.
        if keys.isEmpty {
            if ip == "127.0.0.1" || ip == "::1" { return try await next(request, context) }
            return Self.deny("Management API is disabled until a node key is set in Settings.",
                             status: .forbidden)
        }

        let presented = NodeAuth.presentedKey(request)
        if let presented, keys.contains(where: { NodeAuth.constantTimeEquals($0, presented) }) {
            await AuthLockout.shared.clear(ip)       // valid key wins, before any lockout
            return try await next(request, context)
        }

        if let remaining = await AuthLockout.shared.lockRemaining(ip) {
            return Self.deny("Too many failed attempts. Try again in \(remaining)s.",
                             status: .tooManyRequests)
        }
        await AuthLockout.shared.recordFailure(ip)
        return Self.deny("Missing or invalid key. Send Authorization: Bearer <key>, "
                         + "X-API-Key, or ?api_key=", status: .unauthorized)
    }

    private static func deny(_ message: String, status: HTTPResponse.Status) -> Response {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return Response(status: status,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(data: body)))
    }
}
