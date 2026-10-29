import SwiftUI

/// Colors one line of a pretty-printed debug JSON snapshot so keys and values read differently.
///
/// The tokenizer works on a single line because the view renders lines independently (fold
/// state, hover, lazy layout). A string is a key only when a colon follows it, so a folded
/// `"orders" : [ … ],` line still colors correctly. Colors come from the editor palette, so the
/// inspector follows the same theme as source files.
enum DebugJSONSyntax {
    enum Kind: Equatable {
        case plain
        case key
        case string
        case number
        case boolean
        case null
        case punctuation
    }

    struct Token: Equatable {
        let text: String
        let kind: Kind
    }

    static func tokens(_ line: String) -> [Token] {
        let characters = Array(line)
        var tokens: [Token] = []
        var index = 0

        func take(_ kind: Kind, from start: Int) {
            tokens.append(Token(text: String(characters[start..<index]), kind: kind))
        }

        while index < characters.count {
            let start = index
            let character = characters[index]

            if character == " " || character == "\t" {
                while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
                take(.plain, from: start)
            } else if character == "\"" {
                index += 1
                var escaped = false
                while index < characters.count {
                    let current = characters[index]
                    index += 1
                    if current == "\"" && !escaped { break }
                    escaped = current == "\\" && !escaped
                }
                var next = index
                while next < characters.count, characters[next] == " " || characters[next] == "\t" { next += 1 }
                take(next < characters.count && characters[next] == ":" ? .key : .string, from: start)
            } else if character == "-" || character.isASCII && character.isNumber {
                index += 1
                while index < characters.count, "0123456789.eE+-".contains(characters[index]) { index += 1 }
                take(.number, from: start)
            } else if character.isLetter {
                while index < characters.count, characters[index].isLetter { index += 1 }
                switch String(characters[start..<index]) {
                case "true", "false": take(.boolean, from: start)
                case "null": take(.null, from: start)
                default: take(.plain, from: start)
                }
            } else {
                index += 1
                take(.punctuation, from: start)
            }
        }
        return tokens
    }

    static func styled(_ line: String) -> AttributedString {
        var result = AttributedString()
        for token in tokens(line) {
            var segment = AttributedString(token.text)
            segment.foregroundColor = color(for: token.kind)
            result += segment
        }
        return result
    }

    private static func color(for kind: Kind) -> Color {
        switch kind {
        case .plain: text
        case .key: key
        case .string: string
        case .number: number
        case .boolean: boolean
        case .null: null
        case .punctuation: punctuation
        }
    }

    private static let text = DiffSyntaxHighlighter.syntaxColor(\.text)
    private static let key = DiffSyntaxHighlighter.syntaxColor(\.property)
    private static let string = DiffSyntaxHighlighter.syntaxColor(\.string)
    private static let number = DiffSyntaxHighlighter.syntaxColor(\.number)
    private static let boolean = DiffSyntaxHighlighter.syntaxColor(\.boolean)
    private static let null = DiffSyntaxHighlighter.syntaxColor(\.null)
    private static let punctuation = DiffSyntaxHighlighter.syntaxColor(\.punctuation)
}
