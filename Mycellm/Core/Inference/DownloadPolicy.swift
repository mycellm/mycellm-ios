import Foundation

/// Whether a model transfer is allowed to use the network it would use right now.
///
/// ⚠️ THE DEFAULT WAS PREVIOUSLY "YES, ALWAYS", AND NOTHING SAID SO.
/// `ModelDownloader` built its session from `URLSessionConfiguration.default`
/// and `MLXRepo` used `URLSession.shared`; both leave `allowsCellularAccess`,
/// `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` at true.
/// A four-gigabyte MLX repo would pull over LTE, and over Low Data Mode, with
/// nothing in the way and no indication to the user until the bill arrived.
/// `Connectivity` had known the path was metered the whole time; it was wired
/// only to dimming a label.
///
/// ⚠️ ENFORCED PER-REQUEST, NOT PER-SESSION, because the two download paths
/// don't share a session: the GGUF path owns one, and `MLXRepo` uses
/// `URLSession.shared`, whose configuration cannot be mutated. `URLRequest`
/// carries the same three properties, so setting them on every request covers
/// both paths with one rule instead of two half-rules.
enum DownloadPolicy {

    /// Preference key. Off by default — a metered transfer has to be asked for.
    static let allowExpensiveKey = "allow_expensive_downloads"

    /// Standing permission from Settings. Read from UserDefaults directly so
    /// this is usable from the non-isolated contexts the download paths run in.
    static var allowsExpensiveByDefault: Bool {
        UserDefaults.standard.bool(forKey: allowExpensiveKey)
    }

    /// Why a transfer was refused, or that it may proceed.
    enum Decision: Equatable {
        case allowed
        /// Metered path and no permission — carries the interface so the caller
        /// can say *which* kind of expensive, and act on it.
        case refused(network: String)

        var isAllowed: Bool { self == .allowed }
    }

    /// Decide for a transfer starting now.
    ///
    /// - Parameters:
    ///   - connectivity: current path state.
    ///   - override: a caller opting in for this one transfer (the API's
    ///     `allow_expensive`, or the UI's confirmation). Beats the preference,
    ///     never weakens it — there is no way to *forbid* a transfer that the
    ///     preference already permits, because that would be a footgun with no
    ///     use case.
    static func decide(connectivity: Connectivity, override: Bool = false) -> Decision {
        decide(isExpensive: connectivity.isExpensive,
               isConstrained: connectivity.isConstrained,
               override: override)
    }

    /// The decision itself, over plain conditions.
    ///
    /// Split from the `Connectivity` convenience above so it can be tested:
    /// `Connectivity` reads a live `NWPathMonitor`, so on a wired CI machine
    /// the refusal branch — the only branch that costs a user money if it is
    /// wrong — is unreachable through the wrapper.
    static func decide(isExpensive: Bool, isConstrained: Bool, override: Bool = false) -> Decision {
        guard isExpensive || isConstrained else { return .allowed }
        if override || allowsExpensiveByDefault { return .allowed }
        return .refused(network: isExpensive ? "cellular" : "constrained")
    }

    /// Stamp the effective policy onto a request.
    ///
    /// Belt and braces: the call sites check `decide` first and refuse with a
    /// useful message, but a transfer that slips past that check still must not
    /// silently spend the user's data — URLSession will fail it instead.
    static func apply(to request: inout URLRequest, override: Bool = false) {
        let permitted = override || allowsExpensiveByDefault
        request.allowsExpensiveNetworkAccess = permitted
        request.allowsConstrainedNetworkAccess = permitted
        request.allowsCellularAccess = permitted
    }

    /// A request for `url` with the policy already applied.
    static func request(for url: URL, override: Bool = false) -> URLRequest {
        var r = URLRequest(url: url)
        apply(to: &r, override: override)
        return r
    }

    /// Human-readable refusal, with the size when it is known — the number is
    /// the whole point of telling someone, so a caller can decide.
    static func refusalMessage(network: String, bytes: Int64) -> String {
        // ⚠️ TWO SENTENCES, NOT ONE WITH A SUBSTITUTED NOUN. Splicing a
        // placeholder into the size slot produced "Refusing to download This
        // model over a metered (cellular) connection" whenever the size was
        // unknown — which is every GGUF refusal, since that path has no size
        // until a HEAD request. The unit test asserted the message contained
        // "This model" and so agreed with the bug.
        let what = network == "cellular" ? "a metered (cellular) connection" : "Low Data Mode"
        let opening = bytes > 0
            ? "Refusing to download \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) over \(what)."
            : "Refusing to download this model over \(what)."
        return opening
            + " Retry with allow_expensive:true, or enable large downloads on metered networks in Settings."
    }
}
