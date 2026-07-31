import XCTest
@testable import Mycellm

/// Mirror of the Python node's stop-holdback regression tests: a stop marker
/// arriving split across stream chunks must never leak its prefix, and a
/// withheld prefix that never completes a marker is real content.
final class StopFilterTests: XCTestCase {
    func testPlainTextPassesThrough() {
        var f = StopFilter()
        XCTAssertEqual(f.feed("hello "), "hello ")
        XCTAssertEqual(f.feed("world"), "world")
        XCTAssertEqual(f.flush(), "")
        XCTAssertFalse(f.hitStop)
    }

    func testCompleteMarkerTruncates() {
        var f = StopFilter()
        XCTAssertEqual(f.feed("answer<|im_end|>junk"), "answer")
        XCTAssertTrue(f.hitStop)
        XCTAssertEqual(f.feed("more"), "")
        XCTAssertEqual(f.flush(), "")
    }

    func testSplitMarkerNeverLeaks() {
        var f = StopFilter()
        var out = ""
        for chunk in ["Hello", " world", "<|im", "_end", "|>ignored"] {
            out += f.feed(chunk)
            if f.hitStop { break }
        }
        XCTAssertEqual(out, "Hello world")
        XCTAssertTrue(f.hitStop)
    }

    func testWithheldPrefixFlushedOnFinish() {
        var f = StopFilter()
        var out = ""
        out += f.feed("result: a ")
        out += f.feed("<|im")
        XCTAssertEqual(out, "result: a ")  // "<|im" held back
        out += f.flush()  // generation ended — it was real content
        XCTAssertEqual(out, "result: a <|im")
    }

    func testRequestStopStringsHonored() {
        var f = StopFilter(extraStops: ["FOUR"])
        var out = ""
        for chunk in ["ONE TWO THREE ", "FO", "UR FIVE"] {
            out += f.feed(chunk)
            if f.hitStop { break }
        }
        XCTAssertEqual(out, "ONE TWO THREE ")
        XCTAssertTrue(f.hitStop)
    }

    func testTruncateOneShot() {
        XCTAssertEqual(StopFilter.truncate("code<|im_end|>"), "code")
        XCTAssertEqual(StopFilter.truncate("plain text"), "plain text")
        // HTML strikethrough close tag must NOT be an implicit stop.
        XCTAssertEqual(StopFilter.truncate("a</s>b"), "a</s>b")
    }
}
