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
/// ⚠️ NO PLATFORM DIFFERENCE IN WHAT IS ACCEPTED. An iOS node also belongs to
/// networks that carry fleet keys, and accepting those here was tempting and
/// wrong — see `acceptedKeys()`. HTTP takes `api_key` only, same as Python.
///
struct NodeAuth: Sendable {

    /// Public in the Python sense: no key required, ever. `/metrics` is on this
    /// list because `_PUBLIC_PATHS` in `api/app.py` has it — a scrape target
    /// that needs a credential is a scrape target nobody configures.
    ///
    /// This set is only consulted to carve exceptions *out of*
    /// `protectedPrefixes`; a path that matches no protected prefix is already
    /// open, which is why `/v1/models/{id}` needs no entry here.
    private static let publicPaths: Set<String> = [
        "/health", "/metrics", "/v1/models", "/v1/models/capabilities",
        "/v1/chat/completions", "/v1/completions", "/v1/embeddings",
    ]

    /// Only the management surface is gated.
    private static let protectedPrefixes = ["/v1/node/"]

    static func isProtected(_ path: String) -> Bool {
        if publicPaths.contains(path) { return false }
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    /// The one credential this device is managed with — `api_key`, and nothing
    /// else. Exact parity with the Python node, which also accepts only
    /// `settings.api_key` on HTTP.
    ///
    /// ⚠️ THE FLEET KEY IS DELIBERATELY NOT ACCEPTED HERE, and it is worth
    /// knowing why, because accepting it looks like the friendlier choice.
    /// Fleet control is a *narrower* authority than HTTP management, not an
    /// equal one: both nodes gate fleet commands behind an allowlist —
    /// node.status, node.config, model.list/load/unload/scope (py adds
    /// train.status) — and `_FLEET_COMMANDS` (node.py:492) and FleetHandler's
    /// switch agree on it. The HTTP management surface has no allowlist and
    /// includes models/delete-file, models/remove-config and every relay/*
    /// route. Honouring a fleet key here would let a credential that cannot
    /// unload anything destructive over QUIC delete gigabytes of weights and
    /// re-point a relay over HTTP — the same key, silently more powerful
    /// through the other door.
    ///
    /// Fleet coordination keeps its own channel: QUIC, allowlisted, relayed
    /// through the bootstrap. Reaching a node's full management API means
    /// holding that node's own key, exactly as it does for a Python node.
    ///
    /// Read fresh per request rather than captured at boot, so rotating the key
    /// in Settings takes effect immediately.
    ///
    /// ⚠️ READS UserDefaults DIRECTLY, NOT `Preferences.shared`. Hummingbird
    /// handlers are non-isolated and `Preferences` is @MainActor — the load
    /// handler in HTTPServer already carries this note. Hopping to the main
    /// actor to authenticate every request would also put the UI thread on the
    /// critical path of an inference API.
    static func acceptedKeys() -> [String] {
        let local = UserDefaults.standard.string(forKey: "api_key") ?? ""
        return local.isEmpty ? [] : [local]
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
    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard NodeAuth.isProtected(path) else {
            return try await next(request, context)
        }

        let ip = context.remoteAddress?.ipAddress ?? "unknown"
        let keys = NodeAuth.acceptedKeys()

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
