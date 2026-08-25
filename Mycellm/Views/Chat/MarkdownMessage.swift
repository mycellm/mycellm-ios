import SwiftUI

/// Renders an assistant reply as Markdown, or as its raw source.
///
/// ⚠️ `Text(LocalizedStringKey(content))` WAS DOING THIS BEFORE, AND IT IS NOT
/// A MARKDOWN RENDERER. It picks up a little inline emphasis and nothing else:
/// headings keep their `#`, list items keep their `-`, and a fenced code block
/// arrives as a wall of text with backticks in it. Models answer in Markdown by
/// default, so most replies looked like source that had failed to render —
/// which is exactly what it was.
///
/// Block structure is parsed here; inline spans go through
/// `AttributedString(markdown:)`, which handles emphasis, code spans and links
/// properly and is the part Foundation actually does well.
struct MarkdownMessage: View {
    let source: String
    /// False shows the raw text, for reading or copying what the model really
    /// sent. A renderer that cannot be turned off hides its own mistakes.
    let rendered: Bool
    /// True while tokens are still arriving.
    var streaming: Bool = false

    var body: some View {
        // ⚠️ DO NOT PARSE WHILE STREAMING. This view is built inside the
        // message body, so SwiftUI re-evaluates it on every token — and the
        // document grows with each one. Parsing there is quadratic, and each
        // pass also builds a fresh AttributedString per block. On a 129-frame
        // reply that pinned the main thread: the send button dimmed, the
        // keyboard went black, and the app looked frozen because it was.
        //
        // Streaming text is rendered plainly (cheap, and a half-written
        // document cannot be laid out stably anyway); the moment the reply
        // completes it is parsed once and cached.
        if rendered && !streaming {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.blocks(for: source).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
        } else if rendered {
            Text(source)
                .font(.system(size: 16))
                .foregroundStyle(Color.consoleText)
                .textSelection(.enabled)
        } else {
            Text(source)
                .font(.mono(12))
                .foregroundStyle(Color.consoleText)
                .textSelection(.enabled)
        }
    }

    /// Parsed blocks, memoised by source.
    ///
    /// A finished message still re-renders — scrolling, a sibling updating,
    /// a theme change — and re-parsing then is pure waste. Bounded so a long
    /// conversation cannot grow this without limit.
    private static let cache = NSCache<NSString, BlockBox>()

    private final class BlockBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    static func blocks(for source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownBlock.parse(source)
        cache.countLimit = 200
        cache.setObject(BlockBox(parsed), forKey: key)
        return parsed
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 22 : level == 2 ? 19 : 17, weight: .semibold))
                .foregroundStyle(Color.consoleText)

        case .paragraph(let text):
            inline(text)
                .font(.system(size: 16))
                .foregroundStyle(Color.consoleText)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Color.sporeGreen)
                        inline(item).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 16))
                    .foregroundStyle(Color.consoleText)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(Color.sporeGreen).monospacedDigit()
                        inline(item).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 16))
                    .foregroundStyle(Color.consoleText)
                }
            }

        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language)
                        .font(.mono(9))
                        .foregroundStyle(Color.consoleDim)
                }
                // Code scrolls rather than wraps: a wrapped line changes what
                // the code MEANS in whitespace-sensitive languages.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(.mono(12))
                        .foregroundStyle(Color.sporeGreen)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.voidBlack)
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.relayBlue).frame(width: 2)
                inline(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.consoleDim)
            }

        case .rule:
            Rectangle().fill(Color.cardBorder).frame(height: 1)
        }
    }

    /// Inline spans via Foundation. `.full` so emphasis inside a list item or
    /// heading is honoured too; a failed parse falls back to the literal text
    /// rather than dropping the content.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// The block grammar actually worth supporting for a chat reply.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case numbered([String])
    case code(language: String, body: String)
    case quote(String)
    case rule

    /// A deliberately small parser. Everything here shows up in ordinary model
    /// output; nested lists and tables do not often enough to justify the
    /// ambiguity they bring.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets.removeAll() }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers.removeAll() }
        }
        func flushAll() { flushParagraph(); flushLists() }

        var lines = source.components(separatedBy: .newlines)[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code. An UNCLOSED fence still renders as code — a reply cut
            // off mid-block is the common case while a response is streaming.
            if line.hasPrefix("```") {
                flushAll()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(next)
                }
                blocks.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }

            if line.isEmpty { flushAll(); continue }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                if hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                    flushAll()
                    blocks.append(.heading(
                        level: hashes,
                        text: String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }

            if line == "---" || line == "***" || line == "___" {
                flushAll(); blocks.append(.rule); continue
            }

            if line.hasPrefix("> ") {
                flushAll()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers.removeAll() }
                bullets.append(String(line.dropFirst(2)))
                continue
            }

            if let dot = line.firstIndex(of: "."),
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex,
               line[line.index(after: dot)] == " " {
                flushParagraph()
                if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets.removeAll() }
                numbers.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }

            flushLists()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }
}
