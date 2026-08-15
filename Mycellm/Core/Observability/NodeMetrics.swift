import Foundation

/// Prometheus exposition for `GET /metrics`.
///
/// ⚠️ METRIC NAMES ARE THE CONTRACT, not the values. A scrape config, a
/// recording rule and every dashboard panel key off `mycellm_*` names and label
/// sets defined in `src/mycellm/metrics.py`; an iOS node that invented its own
/// names would be invisible to the fleet's existing Grafana rather than
/// obviously broken. So the names here are copied, and iOS reports the subset it
/// can actually measure — a device has no fleet registry, no bootstrap seeder
/// census and no admission controller, so those series are absent rather than
/// present-and-zero. Absent is honest; zero is a lie a graph will average in.
///
/// Rendered by hand: `prometheus_client` has no Swift equivalent worth a
/// dependency for eleven series, and the text format is stable and trivial.
enum NodeMetrics {

    static let contentType = "text/plain; version=0.0.4; charset=utf-8"

    /// One rendered series line. Labels are escaped per the exposition format.
    static func line(_ name: String, _ value: Double, labels: [String: String] = [:]) -> String {
        let rendered: String
        if labels.isEmpty {
            rendered = name
        } else {
            let pairs = labels
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\"\(escape($0.value))\"" }
                .joined(separator: ",")
            rendered = "\(name){\(pairs)}"
        }
        return "\(rendered) \(format(value))"
    }

    /// Backslash, double-quote and newline are the three characters the text
    /// format requires escaping inside a label value.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Integers render without a decimal point; everything else gets six
    /// places. Prometheus accepts both, but stable formatting keeps diffs and
    /// golden-file tests readable.
    static func format(_ v: Double) -> String {
        guard v.isFinite else { return v > 0 ? "+Inf" : (v < 0 ? "-Inf" : "NaN") }
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(format: "%.6f", v)
    }

    private static func block(_ name: String, _ help: String, _ type: String, _ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return ([
            "# HELP \(name) \(help)",
            "# TYPE \(name) \(type)",
        ] + lines).joined(separator: "\n") + "\n"
    }

    /// Render the current node state. Called per scrape — the equivalent of
    /// Python's `collect_from_node()` immediately followed by `render_metrics()`.
    static func render(node: NodeService) async -> String {
        let activity = node.stats.activity
        let (requests, tokens, errors) = activity.counters
        let models = node.modelManager.loadedModels
        let ledger = node.creditLedger
        let earned = await ledger.totalEarned
        let spent = await ledger.totalSpent

        var out = ""

        out += block(
            "mycellm_uptime_seconds", "Node uptime in seconds", "gauge",
            [line("mycellm_uptime_seconds", node.uptimeSeconds)]
        )

        // Requests carry the same {model,backend,status} labels as Python. iOS
        // records completions and failures without per-model latency histograms
        // — mycellm_inference_latency_seconds is deliberately not emitted
        // rather than emitted with fabricated buckets.
        var requestLines: [String] = []
        if let primary = models.first {
            if requests > 0 {
                requestLines.append(line(
                    "mycellm_inference_requests_total", Double(requests),
                    labels: ["model": primary.name, "backend": primary.backend, "status": "ok"]
                ))
            }
            if errors > 0 {
                requestLines.append(line(
                    "mycellm_inference_requests_total", Double(errors),
                    labels: ["model": primary.name, "backend": primary.backend, "status": "error"]
                ))
            }
        }
        out += block(
            "mycellm_inference_requests_total", "Total inference requests processed", "counter",
            requestLines
        )

        // Python splits prompt vs completion. The iOS activity ring stores the
        // combined count per event, so only the total is truthful here; it is
        // reported under direction="completion" — the series every dashboard
        // panel sums — rather than split with a guess.
        out += block(
            "mycellm_inference_tokens_total", "Total tokens generated", "counter",
            models.first.map { m in
                [line("mycellm_inference_tokens_total", Double(tokens),
                      labels: ["model": m.name, "direction": "completion"])]
            } ?? []
        )

        out += block(
            "mycellm_models_loaded", "Number of currently loaded models", "gauge",
            [line("mycellm_models_loaded", Double(models.count))]
        )

        out += block(
            "mycellm_credits_balance", "Current credit balance", "gauge",
            [line("mycellm_credits_balance", node.stats.creditBalance)]
        )
        out += block(
            "mycellm_credits_earned_total", "Total credits earned from serving inference", "counter",
            [line("mycellm_credits_earned_total", earned)]
        )
        out += block(
            "mycellm_credits_spent_total", "Total credits spent consuming inference", "counter",
            [line("mycellm_credits_spent_total", spent)]
        )

        out += block(
            "mycellm_peers_connected", "Number of connected peers", "gauge",
            [line("mycellm_peers_connected", Double(node.connectedPeerInfo.count))]
        )

        out += block(
            "mycellm_hardware_ram_total_gb", "Total system RAM in GB", "gauge",
            [line("mycellm_hardware_ram_total_gb", HardwareInfo.totalMemoryGB)]
        )
        // Unified memory: the GPU's working set is system RAM, so VRAM is
        // reported as the same figure Python reports for a Metal host.
        out += block(
            "mycellm_hardware_vram_gb", "Available VRAM in GB", "gauge",
            [line("mycellm_hardware_vram_gb", HardwareInfo.totalMemoryGB)]
        )

        return out
    }
}
