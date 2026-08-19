import XCTest
@testable import Mycellm

/// Block parsing for assistant replies.
///
/// ⚠️ THE APP USED `Text(LocalizedStringKey(content))` AND CALLED IT MARKDOWN.
/// That picks up a little inline emphasis and nothing else: headings kept their
/// `#`, list items kept their `-`, and a fenced code block arrived as a wall of
/// text with backticks in it. Models answer in Markdown by default, so most
/// replies looked like source that had failed to render — because it had.
final class MarkdownBlockTests: XCTestCase {

    func testHeadingsByLevel() {
        XCTAssertEqual(MarkdownBlock.parse("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownBlock.parse("### Deep"), [.heading(level: 3, text: "Deep")])
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        // "#1 priority" and a C preprocessor line are ordinary prose.
        XCTAssertEqual(MarkdownBlock.parse("#1 priority"), [.paragraph("#1 priority")])
    }

    func testBulletsCollapseIntoOneList() {
        XCTAssertEqual(MarkdownBlock.parse("- one\n- two\n* three"),
                       [.bullet(["one", "two", "three"])])
    }

    func testNumberedListsKeepTheirOrder() {
        XCTAssertEqual(MarkdownBlock.parse("1. first\n2. second"),
                       [.numbered(["first", "second"])])
    }

    func testSwitchingListTypeStartsANewList() {
        XCTAssertEqual(MarkdownBlock.parse("- a\n1. b"),
                       [.bullet(["a"]), .numbered(["b"])])
    }

    func testFencedCodeKeepsItsWhitespaceExactly() {
        // Indentation is meaning in most languages; joining or trimming lines
        // here would silently corrupt whatever the model wrote.
        let md = "```python\ndef f():\n    return 1\n```"
        XCTAssertEqual(MarkdownBlock.parse(md),
                       [.code(language: "python", body: "def f():\n    return 1")])
    }

    func testAnUnclosedFenceStillRendersAsCode() {
        // THE STREAMING CASE. A reply is parsed while it is still arriving, so
        // the closing fence has usually not been written yet. Treating that as
        // a paragraph would make code flicker into prose and back on every
        // token.
        XCTAssertEqual(MarkdownBlock.parse("```\nhalf a function"),
                       [.code(language: "", body: "half a function")])
    }

    func testCodeIsNotConfusedByMarkdownInsideIt() {
        let md = "```\n# not a heading\n- not a bullet\n```"
        XCTAssertEqual(MarkdownBlock.parse(md),
                       [.code(language: "", body: "# not a heading\n- not a bullet")])
    }

    func testParagraphLinesJoinButBlankLinesSeparate() {
        XCTAssertEqual(MarkdownBlock.parse("one\ntwo\n\nthree"),
                       [.paragraph("one two"), .paragraph("three")])
    }

    func testQuotesAndRules() {
        XCTAssertEqual(MarkdownBlock.parse("> quoted"), [.quote("quoted")])
        XCTAssertEqual(MarkdownBlock.parse("---"), [.rule])
    }

    func testARealisticReplyParsesIntoTheRightShape() {
        let md = """
        ## E2EE

        End-to-end encryption means:

        - only endpoints hold keys
        - the server cannot read messages

        ```swift
        let key = generate()
        ```

        See `docs` for more.
        """
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "E2EE"))
        XCTAssertEqual(blocks[1], .paragraph("End-to-end encryption means:"))
        XCTAssertEqual(blocks[2], .bullet(["only endpoints hold keys",
                                           "the server cannot read messages"]))
        XCTAssertEqual(blocks[3], .code(language: "swift", body: "let key = generate()"))
        XCTAssertEqual(blocks[4], .paragraph("See `docs` for more."))
    }

    func testEmptyInputProducesNothingRatherThanABlankParagraph() {
        XCTAssertTrue(MarkdownBlock.parse("").isEmpty)
        XCTAssertTrue(MarkdownBlock.parse("\n\n   \n").isEmpty)
    }
}

// MARK: - Cost

/// ⚠️ THE RENDERER FROZE THE APP. `MarkdownMessage` is built inside the message
/// body, so SwiftUI re-evaluated it on every token while the document grew —
/// quadratic parsing plus a fresh AttributedString per block, all on the main
/// thread. The send button dimmed and the keyboard went black.
///
/// The fix is structural (no parsing while streaming, memoised afterwards), so
/// these pin the two properties that keep it that way.
extension MarkdownBlockTests {

    func testParsingALongReplyIsCheapEnoughForOnePass() {
        // A long answer parsed ONCE must be trivial. This is the budget the
        // streaming guard exists to protect: if a single pass ever gets
        // expensive, doing it per token is catastrophic rather than merely bad.
        let doc = (0..<400).map { "- item \($0) with some **emphasis** in it" }
            .joined(separator: "\n")
        measure { _ = MarkdownBlock.parse(doc) }
    }

    func testRepeatedRendersOfTheSameReplyReuseTheParse() {
        // A finished message still re-renders when scrolled or when a sibling
        // updates. The second call must come from cache, not re-parse.
        let doc = "# Title\n\n- a\n- b\n\n```swift\nlet x = 1\n```"
        let first = MarkdownMessage.blocks(for: doc)
        let second = MarkdownMessage.blocks(for: doc)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 3)
    }

    func testAGrowingDocumentDoesNotReuseAStaleParse() {
        // The cache is keyed by content, so the partial and the completed reply
        // are different entries — a stale hit would freeze the message at
        // whatever it looked like mid-stream.
        let partial = "# Title\n\n- a"
        let complete = "# Title\n\n- a\n- b"
        XCTAssertNotEqual(MarkdownMessage.blocks(for: partial),
                          MarkdownMessage.blocks(for: complete))
    }
}
