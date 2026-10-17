import AppKit
import SwiftUI
import LitheAgentConversationModule

/// Block-level Markdown of an Agent reply: headings, lists, quotes, tables,
/// rules and fenced code. Inline syntax inside each block uses Foundation's
/// inline parser. Unclosed fences (still streaming) are treated as code.
enum AgentMarkdownBlock: Equatable {
    struct ListItem: Equatable {
        let marker: String
        let depth: Int
        let text: AttributedString
    }

    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case list([ListItem])
    case quote(AttributedString)
    case code(language: String, code: String)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case rule

    /// Parsed blocks are cached by source text. Rows are re-evaluated on every
    /// transcript update, and long history would otherwise be parsed again each time.
    @MainActor
    static func blocks(of text: String) -> [AgentMarkdownBlock] {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let blocks = parse(text)
        cache.setObject(CachedBlocks(blocks), forKey: key, cost: text.utf16.count)
        return blocks
    }

    private final class CachedBlocks {
        let blocks: [AgentMarkdownBlock]
        init(_ blocks: [AgentMarkdownBlock]) { self.blocks = blocks }
    }

    @MainActor private static let cache: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.countLimit = 800
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func parse(_ text: String) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        var paragraph: [Substring] = []
        var quote: [Substring] = []
        var items: [ListItem] = []
        var table: [Substring] = []
        var code: [Substring] = []
        var language = ""
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(inline(quote.joined(separator: "\n"))))
            quote.removeAll()
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items.removeAll()
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            if table.count >= 2, isTableSeparator(table[1]) {
                let header = cells(table[0]).map(inline)
                let rows = table.dropFirst(2).map { cells($0).map(inline) }
                blocks.append(.table(header: header, rows: Array(rows)))
            } else {
                paragraph.append(contentsOf: table)
                flushParagraph()
            }
            table.removeAll()
        }
        func flushAll() { flushParagraph(); flushQuote(); flushList(); flushTable() }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    code.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inCode = true
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph(); flushQuote(); flushList()
                table.append(trimmed)
                continue
            }
            flushTable()
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(trimmed.dropFirst().drop { $0 == " " })
            } else if let item = listItem(line) {
                flushParagraph(); flushQuote()
                items.append(item)
            } else if !items.isEmpty, line.first == " " || line.first == "\t" {
                // Continuation line of the previous list item.
                let last = items.removeLast()
                var text = last.text
                text.append(AttributedString(" "))
                text.append(inline(String(trimmed)))
                items.append(ListItem(marker: last.marker, depth: last.depth, text: text))
            } else {
                flushQuote(); flushList()
                paragraph.append(line)
            }
        }
        if inCode {
            blocks.append(.code(language: language, code: code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func inline<S: StringProtocol>(_ text: S) -> AttributedString {
        let source = String(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        // Parsing loses the identity of escaped/entity asterisks. Leave such
        // blocks as parsed rather than turning their literal markers into bold.
        let hasLiteralAsterisk = source.contains("\\*") || source.range(
            of: #"&(?:ast|midast|#0*42|#[xX]0*2[aA]);"#, options: .regularExpression) != nil
        return hasLiteralAsterisk ? parsed : pairingLeftoverStrongMarkers(parsed)
    }

    /// CommonMark closes `**` only when it is right-flanking, so `**状态：**仍开放`
    /// (CJK punctuation before the marker, a CJK letter after it) stays literal.
    /// Agents write this form constantly in Chinese replies. Markers Foundation
    /// left as text are paired again with only the whitespace part of the
    /// flanking rule: an opener is not followed by whitespace and a closer is not
    /// preceded by it, so `2 ** 3` stays literal. Code spans are skipped and an
    /// unpaired marker stays literal. Code spans and link labels retain their
    /// Foundation parsing so independent link labels cannot form a marker pair.
    static func pairingLeftoverStrongMarkers(_ text: AttributedString) -> AttributedString {
        let characters = Array(text.characters)
        func isSpace(_ offset: Int) -> Bool {
            !characters.indices.contains(offset) || characters[offset].isWhitespace
        }
        var pairs: [(open: Int, close: Int)] = []
        var opener: Int?
        var searchStart = text.startIndex
        while searchStart < text.endIndex, let range = text[searchStart...].range(of: "**") {
            searchStart = range.upperBound
            guard !text[range].runs.contains(where: {
                $0.inlinePresentationIntent?.contains(.code) == true || $0.link != nil
            }) else { continue }
            let offset = text.characters.distance(from: text.startIndex, to: range.lowerBound)
            let canOpen = !isSpace(offset + 2), canClose = !isSpace(offset - 1)
            if let open = opener, canClose, offset > open + 2 {
                pairs.append((open, offset))
                opener = nil
            } else if canOpen {
                opener = offset
            }
        }
        var result = text
        for (open, close) in pairs.reversed() {
            let start = result.index(result.startIndex, offsetByCharacters: open)
            let closeStart = result.index(result.startIndex, offsetByCharacters: close)
            let content = result.index(start, offsetByCharacters: 2)..<closeStart
            let runs = result[content].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
            for (range, intent) in runs {
                result[range].inlinePresentationIntent = intent.union(.stronglyEmphasized)
            }
            result.removeSubrange(closeStart..<result.index(closeStart, offsetByCharacters: 2))
            result.removeSubrange(start..<result.index(start, offsetByCharacters: 2))
        }
        return result
    }

    private static func heading(_ line: Substring) -> AgentMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: inline(line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)))
    }

    private static func isRule(_ line: Substring) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: Substring) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(indent.count)
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            var rest = body.dropFirst(2)
            var marker = "•"
            if rest.hasPrefix("[ ] ") { marker = "☐"; rest = rest.dropFirst(4) }
            else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { marker = "☑"; rest = rest.dropFirst(4) }
            return ListItem(marker: marker, depth: min(depth, 4), text: inline(rest))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return ListItem(marker: digits + ".", depth: min(depth, 4), text: inline(after.dropFirst(2)))
    }

    private static func cells(_ line: Substring) -> [Substring] {
        var row = line.trimmingCharacters(in: .whitespaces)[...]
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row = row.dropLast() }
        // GFM: `\|` is a literal pipe inside a cell, including in code spans.
        var result: [Substring] = []
        var cell = ""
        var previous: Character?
        for character in row {
            if character == "|" {
                if previous == "\\" {
                    cell.removeLast()
                    cell.append("|")
                } else {
                    result.append(cell.trimmingCharacters(in: .whitespaces)[...])
                    cell = ""
                }
            } else {
                cell.append(character)
            }
            previous = character
        }
        result.append(cell.trimmingCharacters(in: .whitespaces)[...])
        return result
    }

    private static func isTableSeparator(_ line: Substring) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}

/// Resolves inline Markdown runs to explicit bundled faces. Letting SwiftUI
/// synthesize bold or italic traits on the custom Inter font drops its system
/// fallback cascade, and CJK text in those runs rendered as missing glyphs.
enum AgentMarkdownInline {
    static func styled(_ text: AttributedString, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var result = text
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let range = run.range
            if intent.contains(.code) {
                result[range].swiftUI.font = LitheTheme.uiFont(size: size - 1, design: .monospaced)
                result[range].swiftUI.backgroundColor = LitheTheme.toolHeaderInactive
            } else {
                let bold = intent.contains(.stronglyEmphasized)
                result[range].swiftUI.font = font(size: size, weight: bold ? .semibold : weight,
                                                  italic: intent.contains(.emphasized))
            }
            if intent.contains(.strikethrough) { result[range].swiftUI.strikethroughStyle = .single }
            if run.link != nil { result[range].swiftUI.foregroundColor = LitheTheme.accent }
            result[range].inlinePresentationIntent = nil
        }
        return result
    }

    /// Text for styled runs, with a kind icon before each file or GitHub link.
    /// Plain web links keep only the link color.
    @MainActor
    static func text(_ styled: AttributedString, size: CGFloat) -> Text {
        var text: Text?
        var pending = AttributedString()
        var previousLink: URL?
        func append(_ segment: Text) { text = text.map { $0 + segment } ?? segment }
        for run in styled.runs {
            if let link = run.link, link != previousLink,
               let icon = AgentMarkdownLink(link).icon(size: size) {
                if !pending.characters.isEmpty { append(Text(pending)); pending = AttributedString() }
                append(icon + Text(verbatim: "\u{2009}"))
            }
            pending.append(styled[run.range])
            previousLink = run.link
        }
        guard let text else { return Text(pending) }
        return pending.characters.isEmpty ? text : text + Text(pending)
    }

    private static func font(size: CGFloat, weight: Font.Weight, italic: Bool) -> Font {
        guard italic else { return LitheTheme.uiFont(size: size, weight: weight) }
        let face: String
        switch weight {
        case .medium: face = "MediumItalic"
        case .semibold: face = "SemiBoldItalic"
        case .bold: face = "BoldItalic"
        default: face = "Italic"
        }
        return Font.custom("Inter-\(face)", size: size)
    }
}

/// Renders the reply blocks. Equatable on the source text so streaming
/// updates elsewhere in the transcript do not re-render settled replies.
struct AgentMarkdownMessage: View, Equatable {
    let text: String
    /// Replies read at 13pt; reasoning uses a quieter size.
    var size: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AgentMarkdownBlock.blocks(of: text).enumerated()), id: \.offset) { _, block in
                AgentMarkdownBlockView(block: block, size: size)
            }
        }
        .font(LitheTheme.uiFont(size: size))
        .textSelection(.enabled)
    }
}

private struct AgentMarkdownBlockView: View {
    let block: AgentMarkdownBlock
    let size: CGFloat

    var body: some View {
        switch block {
        case .paragraph(let text):
            AgentMarkdownInline.text(AgentMarkdownInline.styled(text, size: size), size: size)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            AgentMarkdownInline.text(AgentMarkdownInline.styled(text, size: headingSize(level), weight: .semibold), size: headingSize(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: item.marker)
                            .foregroundStyle(LitheTheme.secondaryText)
                            .monospacedDigit()
                            .frame(minWidth: 12, alignment: .trailing)
                        AgentMarkdownInline.text(AgentMarkdownInline.styled(item.text, size: size), size: size)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(LitheTheme.panelBorder).frame(width: 3)
                AgentMarkdownInline.text(AgentMarkdownInline.styled(text, size: size), size: size)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            AgentCodeBlock(language: language, code: code)
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            tableCell(AgentMarkdownInline.styled(cell, size: size - 0.5, weight: .semibold))
                        }
                    }
                    .background(LitheTheme.toolHeaderInactive)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider().overlay(LitheTheme.panelBorder)
                        GridRow {
                            ForEach(0..<header.count, id: \.self) { column in
                                tableCell(AgentMarkdownInline.styled(column < row.count ? row[column] : AttributedString(), size: size - 0.5))
                            }
                        }
                    }
                }
                .font(LitheTheme.uiFont(size: 12.5))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.panelBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .litheScrollViewChrome()
            .modifier(AgentHoverCopy(text: AgentMarkdownTableExport.markdown(header: header, rows: rows),
                                     html: AgentMarkdownTableExport.html(header: header, rows: rows),
                                     help: "Copy table"))
        case .rule:
            Divider().overlay(LitheTheme.panelBorder).padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        size + (level == 1 ? 4 : level == 2 ? 2 : 0.5)
    }

    private func tableCell(_ text: AttributedString) -> some View {
        AgentMarkdownTableCellLayout {
            AgentMarkdownInline.text(text, size: size - 0.5)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}

/// Horizontal scrolling proposes no width. Measure the text again at the cell's
/// bounded width so Grid receives its wrapped height instead of a single line.
private struct AgentMarkdownTableCellLayout: Layout {
    private static let maximumWidth: CGFloat = 320

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let cell = subviews.first else { return .zero }
        let width = min(Self.maximumWidth, proposal.width ?? cell.sizeThatFits(.unspecified).width)
        return cell.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

struct AgentCodeBlock: View {
    @Environment(\.locale) private var locale
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? AgentLocalization.string("code", locale: locale) : language)
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
                Spacer()
                AgentCopyButton(text: code, help: "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(LitheTheme.toolHeaderInactive)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(LitheTheme.codeFont)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }
}

/// Copies text to the general pasteboard and briefly confirms with a checkmark.
struct AgentCopyButton: View {
    let text: String
    /// Rich form for editors and spreadsheets that paste HTML tables.
    var html: String?
    var help: LocalizedStringKey = "Copy"
    @State private var didCopy = false

    var body: some View {
        Button {
            AgentPasteboard.copy(text, html: html)
            didCopy = true
            Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(LitheTheme.uiFont(size: 10.5))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .foregroundStyle(didCopy ? LitheTheme.success : LitheTheme.tertiaryText)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum AgentPasteboard {
    static func copy(_ text: String, html: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let html { NSPasteboard.general.setString(html, forType: .html) }
    }
}

/// A copy button in the top-trailing corner that appears while the block is hovered.
private struct AgentHoverCopy: ViewModifier {
    let text: String
    let html: String?
    let help: LocalizedStringKey
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                AgentCopyButton(text: text, html: html, help: help)
                    .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
            .onHover { isHovered = $0 }
    }
}

/// A single table as Markdown for plain-text targets and HTML for spreadsheets.
/// Inline formatting is dropped; cell text is kept verbatim.
enum AgentMarkdownTableExport {
    static func markdown(header: [AttributedString], rows: [[AttributedString]]) -> String {
        func line(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }
        let width = header.count
        var lines = [line(header.map { markdownCell(plain($0)) }), line(Array(repeating: "---", count: width))]
        lines += rows.map { line(cells($0, width: width).map(markdownCell)) }
        return lines.joined(separator: "\n")
    }

    static func html(header: [AttributedString], rows: [[AttributedString]]) -> String {
        func row(_ cells: [String], tag: String) -> String {
            "<tr>" + cells.map { "<\(tag)>\(escape($0))</\(tag)>" }.joined() + "</tr>"
        }
        let body = rows.map { row(cells($0, width: header.count), tag: "td") }.joined()
        return "<table><thead>\(row(header.map(plain), tag: "th"))</thead><tbody>\(body)</tbody></table>"
    }

    private static func markdownCell(_ text: String) -> String {
        // The source formatting has already been removed. Escape inline syntax
        // and HTML/entity introducers so it cannot be interpreted a second time.
        let syntax: Set<Character> = ["\\", "`", "*", "_", "[", "]", "!", "<", ">", "&", "~", "|", ":", "."]
        let last = text.count - 1
        return text.enumerated().map { offset, character in
            // Literal line breaks split table rows; edge whitespace is trimmed
            // by table parsers. Character references retain the visible text.
            if character.isNewline || (character.isWhitespace && (offset == 0 || offset == last)) {
                return character.unicodeScalars.map { "&#\($0.value);" }.joined()
            }
            return syntax.contains(character) ? "\\" + String(character) : String(character)
        }.joined()
    }

    private static func plain(_ text: AttributedString) -> String { String(text.characters) }

    private static func cells(_ row: [AttributedString], width: Int) -> [String] {
        (0..<width).map { $0 < row.count ? plain(row[$0]) : "" }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Plain Markdown of a conversation for the clipboard: user prompts and Agent
/// replies in order, tool calls as one line each, reasoning omitted.
enum AgentTranscriptExport {
    static func markdown(title: String?, messages: [AgentConversationMessage], locale: Locale) -> String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append("# " + title) }
        let you = AgentLocalization.string("You", locale: locale)
        let agent = AgentLocalization.string("Agent", locale: locale)
        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case .user where !text.isEmpty: parts.append("**\(you):**\n\n" + text)
            case .agent where !text.isEmpty: parts.append("**\(agent):**\n\n" + text)
            case .tool where !text.isEmpty: parts.append("> " + text.replacingOccurrences(of: "\n", with: " "))
            default: continue
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
