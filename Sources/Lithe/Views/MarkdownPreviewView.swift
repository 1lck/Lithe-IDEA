import Foundation
import SwiftUI

struct MarkdownPreviewView: View {
    @ObservedObject var document: EditorDocument

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(document.text)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if blocks.isEmpty {
                    Text("Nothing to preview")
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.top, 12)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(LitheTheme.editor)
        .textSelection(.enabled)
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote([String])
    case code(language: String?, text: String)
    case divider
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            markdownText(text)
                .font(headingFont(for: level))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.top, level == 1 ? 0 : 16)
                .padding(.bottom, level == 1 ? 14 : 8)

        case let .paragraph(text):
            markdownText(text)
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.primaryText)
                .lineSpacing(4)
                .padding(.bottom, 14)

        case let .unorderedList(items):
            listView(items: items, ordered: false)

        case let .orderedList(items):
            listView(items: items, ordered: true)

        case let .quote(lines):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(LitheTheme.accent.opacity(0.75))
                    .frame(width: 3)
                markdownText(lines.joined(separator: "\n"))
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineSpacing(4)
            }
            .padding(.leading, 4)
            .padding(.bottom, 16)

        case let .code(language, text):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.bottom, 8)
                }
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(LitheTheme.divider.opacity(0.9), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(.bottom, 16)

        case .divider:
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func listView(items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: 13, weight: ordered ? .regular : .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: ordered ? 22 : 14, alignment: ordered ? .trailing : .center)
                    markdownText(item)
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineSpacing(3)
                }
            }
        }
        .padding(.leading, 3)
        .padding(.bottom, 16)
    }

    private func markdownText(_ source: String) -> Text {
        guard let attributed = try? AttributedString(markdown: source) else {
            return Text(source)
        }
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .system(size: 26, weight: .bold)
        case 2: .system(size: 21, weight: .bold)
        case 3: .system(size: 18, weight: .semibold)
        case 4: .system(size: 15, weight: .semibold)
        default: .system(size: 14, weight: .semibold)
        }
    }
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let sourceLines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < sourceLines.count {
            let line = sourceLines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceInfo(for: line) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < sourceLines.count, !isClosingFence(sourceLines[index], marker: fence.marker) {
                    codeLines.append(sourceLines[index])
                    index += 1
                }
                if index < sourceLines.count { index += 1 }
                blocks.append(.code(language: fence.language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingInfo(for: line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let firstItem = unorderedItem(for: line) {
                flushParagraph()
                var items = [firstItem]
                index += 1
                while index < sourceLines.count, let item = unorderedItem(for: sourceLines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let firstItem = orderedItem(for: line) {
                flushParagraph()
                var items = [firstItem]
                index += 1
                while index < sourceLines.count, let item = orderedItem(for: sourceLines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if let quoteLine = quoteItem(for: line) {
                flushParagraph()
                var quoteLines = [quoteLine]
                index += 1
                while index < sourceLines.count, let item = quoteItem(for: sourceLines[index]) {
                    quoteLines.append(item)
                    index += 1
                }
                blocks.append(.quote(quoteLines))
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func headingInfo(for line: String) -> (level: Int, text: String)? {
        guard line.first == "#" else { return nil }
        let characters = Array(line)
        var level = 0
        while level < characters.count, characters[level] == "#" {
            level += 1
        }
        guard level <= 6, level < characters.count,
              characters[level] == " " || characters[level] == "\t" else { return nil }
        let text = String(characters.dropFirst(level + 1))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
        return (level, text)
    }

    private static func fenceInfo(for line: String) -> (marker: Character, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }
        let markerCount = trimmed.prefix { $0 == marker }.count
        guard markerCount >= 3 else { return nil }
        let language = String(trimmed.dropFirst(markerCount)).trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? nil : language)
    }

    private static func isClosingFence(_ line: String, marker: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let markerCount = trimmed.prefix { $0 == marker }.count
        return markerCount >= 3 && trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func unorderedItem(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" else {
            return nil
        }
        let remainder = trimmed.dropFirst()
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        return remainder.trimmingCharacters(in: .whitespaces)
    }

    private static func orderedItem(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        var digitCount = 0
        while digitCount < characters.count, characters[digitCount].isNumber {
            digitCount += 1
        }
        guard digitCount > 0, digitCount + 1 < characters.count,
              characters[digitCount] == "." || characters[digitCount] == ")",
              characters[digitCount + 1] == " " || characters[digitCount + 1] == "\t" else {
            return nil
        }
        return String(characters.dropFirst(digitCount + 2))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func quoteItem(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }

}
