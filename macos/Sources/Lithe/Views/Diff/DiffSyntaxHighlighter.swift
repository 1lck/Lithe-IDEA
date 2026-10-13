import SwiftUI
import LitheGitModule

enum DiffSide { case left, right }

enum DiffSyntaxHighlighter {
    private struct Token {
        let text: String
        let color: Color
    }

    // Reuse the editor's configured syntax colors instead of UI status colors.
    private static func syntaxColor(_ keyPath: KeyPath<SyntaxHighlightingPalette, NSColor>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = CodeEditorPalette(isDark: dark, theme: LitheTheme.activeTheme)
            return SyntaxHighlightingColorConfiguration.bundled.palette(formatID: nil, base: base)[keyPath: keyPath]
        })
    }
    private static let keywordColor = syntaxColor(\.keyword)
    private static let typeColor = syntaxColor(\.type)
    private static let stringColor = syntaxColor(\.string)
    private static let numberColor = syntaxColor(\.number)
    private static let commentColor = syntaxColor(\.comment)
    private static let tagColor = syntaxColor(\.annotation)
    private static let baseColor = Color(nsColor: NSColor(name: nil) { appearance in
        CodeEditorPalette(isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                          theme: LitheTheme.activeTheme).text
    })

    private static let keywords: Set<String> = [
        "class", "struct", "enum", "protocol", "extension", "func", "let", "var", "if", "else",
        "guard", "switch", "case", "for", "while", "return", "throw", "throws", "try", "catch",
        "async", "await", "public", "private", "internal", "protected", "static", "final", "new",
        "import", "package", "interface", "implements", "extends", "void", "boolean", "int", "long",
        "const", "function", "def", "in", "from", "as", "true", "false", "null", "nil", "self", "this"
    ]

    static func styled(
        _ text: String,
        comparing otherText: String?,
        fileExtension: String,
        side: DiffSide,
        highlightsWords: Bool
    ) -> AttributedString {
        let pair = highlightsWords && otherText != nil
            ? DiffSplitLayout.InlineHighlight.compare(side == .left ? text : otherText!, side == .left ? otherText! : text)
            : (left: nil, right: nil)
        return styled(text, fileExtension: fileExtension, highlight: side == .left ? pair.left : pair.right)
    }

    static func styled(_ text: String, fileExtension: String, highlight: DiffSplitLayout.InlineHighlight?) -> AttributedString {
        let tokens = tokenize(text, fileExtension: fileExtension.lowercased())
        let highlightRange = highlight?.range
        let highlightColor = highlight?.kind == .addition ? LitheTheme.Diff.inserted
            : highlight?.kind == .removal ? LitheTheme.Diff.deleted : LitheTheme.Diff.modifiedWord
        var result = AttributedString()
        var globalOffset = 0

        for token in tokens {
            let characters = Array(token.text)
            let tokenStart = globalOffset
            let tokenEnd = tokenStart + characters.count
            let localHighlightStart = highlightRange.map { max(0, $0.lowerBound - tokenStart) } ?? 0
            let localHighlightEnd = highlightRange.map { min(characters.count, $0.upperBound - tokenStart) } ?? 0

            if let highlightRange,
               tokenEnd > highlightRange.lowerBound,
               tokenStart < highlightRange.upperBound,
               localHighlightStart < localHighlightEnd {
                append(characters[0..<localHighlightStart], color: token.color, background: nil, to: &result)
                append(
                    characters[localHighlightStart..<localHighlightEnd],
                    color: token.color,
                    background: highlightColor,
                    to: &result
                )
                append(characters[localHighlightEnd..<characters.count], color: token.color, background: nil, to: &result)
            } else {
                append(characters[0..<characters.count], color: token.color, background: nil, to: &result)
            }
            globalOffset = tokenEnd
        }
        return result
    }

    private static func append(
        _ characters: ArraySlice<Character>,
        color: Color,
        background: Color?,
        to result: inout AttributedString
    ) {
        guard !characters.isEmpty else { return }
        var segment = AttributedString(String(characters))
        segment.foregroundColor = color
        if let background {
            segment.backgroundColor = background
        }
        result += segment
    }

    private static func tokenize(_ text: String, fileExtension: String) -> [Token] {
        if ["xml", "html", "xhtml", "plist"].contains(fileExtension) {
            return tokenizeMarkup(text)
        }
        if ["md", "markdown"].contains(fileExtension), text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return [Token(text: text, color: commentColor)]
        }
        return tokenizeCode(text)
    }

    private static func tokenizeMarkup(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let start = index
            if characters[index] == "<" {
                while index < characters.count, characters[index] != ">" {
                    index += 1
                }
                if index < characters.count { index += 1 }
                tokens.append(Token(text: String(characters[start..<index]), color: tagColor))
            } else {
                while index < characters.count, characters[index] != "<" {
                    index += 1
                }
                tokens.append(Token(text: String(characters[start..<index]), color: baseColor))
            }
        }
        return tokens
    }

    private static func tokenizeCode(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let start = index
            let character = characters[index]

            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                tokens.append(Token(text: String(characters[index...]), color: commentColor))
                break
            }

            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                var escaped = false
                while index < characters.count {
                    let current = characters[index]
                    index += 1
                    if current == quote && !escaped { break }
                    escaped = current == "\\" && !escaped
                    if current != "\\" { escaped = false }
                }
                tokens.append(Token(text: String(characters[start..<index]), color: stringColor))
                continue
            }

            if character.isNumber {
                index += 1
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    index += 1
                }
                tokens.append(Token(text: String(characters[start..<index]), color: numberColor))
                continue
            }

            if character.isLetter || character == "_" || character == "@" {
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                let word = String(characters[start..<index])
                let color: Color
                if word.hasPrefix("@") {
                    color = tagColor
                } else if keywords.contains(word) {
                    color = keywordColor
                } else if word.first?.isUppercase == true {
                    color = typeColor
                } else {
                    color = baseColor
                }
                tokens.append(Token(text: word, color: color))
                continue
            }

            index += 1
            while index < characters.count {
                let next = characters[index]
                if next.isLetter || next.isNumber || next == "_" || next == "@" || next == "\"" || next == "'" {
                    break
                }
                if next == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    break
                }
                index += 1
            }
            tokens.append(Token(text: String(characters[start..<index]), color: baseColor))
        }
        return tokens
    }
}
