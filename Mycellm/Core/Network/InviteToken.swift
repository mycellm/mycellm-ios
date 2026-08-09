import Foundation

/// Parses the Python host's portable invite token — urlsafe-base64 JSON from
/// `InviteToken.to_portable()` — so joining with an invite adopts the host's
/// REAL network_id (sha256-derived). Without it a manual join invents a local
/// UUID that can never match the host's hosted id, which makes join-key claims
/// impossible to authorize.
struct ParsedInvite: Sendable, Equatable {
    let networkId: String
    let tokenId: String

    /// Accepts a raw portable token or a mycellm.dev/join URL containing one
    /// (`https://mycellm.dev/join?token=<tok>` or `/join/<tok>`).
    static func parse(_ input: String) -> ParsedInvite? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let candidate: String
        if s.contains("/join"), let url = URL(string: s) {
            if let tok = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value {
                candidate = tok
            } else if let last = url.pathComponents.last, last != "join" {
                candidate = last
            } else {
                return nil
            }
        } else {
            candidate = s
        }

        // urlsafe base64: -_ alphabet, padding often stripped by copy/paste.
        var b64 = candidate
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }

        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let networkId = obj["network_id"] as? String,
              !networkId.isEmpty else {
            return nil
        }
        return ParsedInvite(
            networkId: networkId,
            tokenId: obj["token_id"] as? String ?? ""
        )
    }
}
