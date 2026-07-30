import Foundation

/// Streaming stop-string filter — Swift mirror of the Python node's
/// `chat_stop_strings` / `truncate_at_stops` / `stop_holdback_len`.
///
/// MLXLMCommon stops on the tokenizer's EOS, but several chat templates end
/// turns with a marker that is NOT the eos token (Qwen's `<|im_end|>` with
/// eos `<|endoftext|>` is the canonical case), so the literal marker — or,
/// worse, its prefix — leaks into streamed output. The filter withholds any
/// text tail that could still become a stop marker until the next chunk
/// disambiguates it; `flush()` releases a tail that never completed one.
struct StopFilter {
    /// Well-known chat-template terminators (deliberately excludes "</s>",
    /// which appears in legitimate HTML; a real </s> eos arrives as EOS).
    static let chatEndMarkers = ["<|im_end|>", "<|eot_id|>", "<|end|>", "<|endoftext|>"]

    private let stops: [String]
    private var seen = ""
    private var sentLen = 0
    private(set) var hitStop = false

    init(extraStops: [String] = []) {
        var s = extraStops
        for m in Self.chatEndMarkers where !s.contains(m) { s.append(m) }
        stops = s
    }

    /// Feed one streamed chunk; returns the text safe to emit now ("" often).
    mutating func feed(_ chunk: String) -> String {
        guard !hitStop else { return "" }
        seen += chunk
        // Complete stop marker anywhere in accumulated text → emit up to it.
        var cut = seen.endIndex
        for s in stops {
            if let r = seen.range(of: s), r.lowerBound < cut { cut = r.lowerBound }
        }
        if cut != seen.endIndex {
            hitStop = true
            let upto = seen.distance(from: seen.startIndex, to: cut)
            let start = seen.index(seen.startIndex, offsetBy: min(sentLen, upto))
            let out = String(seen[start..<cut])
            sentLen = upto
            return out
        }
        // Withhold a suffix that is a proper prefix of any stop marker.
        var hold = 0
        for s in stops {
            let maxK = min(s.count - 1, seen.count)
            if maxK <= hold { continue }
            for k in stride(from: maxK, through: hold + 1, by: -1) {
                if seen.hasSuffix(String(s.prefix(k))) { hold = k; break }
            }
        }
        let sendTo = seen.count - hold
        guard sendTo > sentLen else { return "" }
        let lo = seen.index(seen.startIndex, offsetBy: sentLen)
        let hi = seen.index(seen.startIndex, offsetBy: sendTo)
        sentLen = sendTo
        return String(seen[lo..<hi])
    }

    /// Generation ended without completing a withheld prefix — it was real
    /// content after all. Returns the remaining unsent text (empty after a
    /// stop hit).
    mutating func flush() -> String {
        guard !hitStop, sentLen < seen.count else { return "" }
        let lo = seen.index(seen.startIndex, offsetBy: sentLen)
        sentLen = seen.count
        return String(seen[lo...])
    }

    /// One-shot helper for non-streaming completions.
    static func truncate(_ text: String, extraStops: [String] = []) -> String {
        var f = StopFilter(extraStops: extraStops)
        let head = f.feed(text)
        return head + f.flush()
    }
}
