import XCTest
@testable import Mycellm

/// The Prometheus text format is unforgiving — a malformed line makes a scrape
/// drop the whole payload, so the rendering primitives are checked directly.
final class NodeMetricsTests: XCTestCase {

    func testContentTypeMatchesPython() {
        XCTAssertEqual(NodeMetrics.contentType, "text/plain; version=0.0.4; charset=utf-8")
    }

    func testUnlabelledSeries() {
        XCTAssertEqual(NodeMetrics.line("mycellm_models_loaded", 2), "mycellm_models_loaded 2")
    }

    /// Labels are emitted in sorted key order so a scrape diff is stable
    /// between runs rather than reordering with dictionary hashing.
    func testLabelsAreSortedAndQuoted() {
        let line = NodeMetrics.line(
            "mycellm_inference_requests_total", 5,
            labels: ["status": "ok", "model": "qwen3", "backend": "llama.cpp"]
        )
        XCTAssertEqual(
            line,
            #"mycellm_inference_requests_total{backend="llama.cpp",model="qwen3",status="ok"} 5"#
        )
    }

    func testLabelValuesAreEscaped() {
        XCTAssertEqual(NodeMetrics.escape(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(NodeMetrics.escape(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(NodeMetrics.escape("two\nlines"), #"two\nlines"#)
    }

    /// A model name with a quote in it must not break out of the label value
    /// and corrupt every following series in the scrape.
    func testQuoteInLabelValueCannotBreakTheLine() {
        let line = NodeMetrics.line("m", 1, labels: ["model": #"we"ird"#])
        XCTAssertEqual(line, #"m{model="we\"ird"} 1"#)
    }

    func testIntegralValuesRenderWithoutDecimals() {
        XCTAssertEqual(NodeMetrics.format(0), "0")
        XCTAssertEqual(NodeMetrics.format(42), "42")
        XCTAssertEqual(NodeMetrics.format(-7), "-7")
    }

    func testFractionalValuesRenderWithFixedPrecision() {
        XCTAssertEqual(NodeMetrics.format(1.5), "1.500000")
        XCTAssertEqual(NodeMetrics.format(0.125), "0.125000")
    }

    /// Infinity and NaN have literal spellings in the exposition format; the
    /// default numeric formatting would emit "inf"/"nan", which fails parsing.
    func testNonFiniteValuesUsePrometheusSpellings() {
        XCTAssertEqual(NodeMetrics.format(.infinity), "+Inf")
        XCTAssertEqual(NodeMetrics.format(-.infinity), "-Inf")
        XCTAssertEqual(NodeMetrics.format(.nan), "NaN")
    }
}
