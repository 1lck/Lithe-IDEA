import Foundation

/// A command line laid out for reading, as styled runs per line.
struct CommandLineDisplay: Equatable {
    enum Role: Equatable {
        case text
        /// `-x` / `--name`, without an `=value` suffix.
        case option
        case jsonKey
        case jsonString
        case jsonNumber
        /// `true`, `false` and `null`.
        case jsonLiteral
        case jsonPunctuation
    }

    struct Run: Equatable {
        let text: String
        let role: Role
    }

    /// Display lines; a continuation line starts with its indentation run.
    let lines: [[Run]]

    var text: String {
        lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }
}

/// Lays out a process command line for confirmation dialogs.
///
/// Rust Core reports a command as its arguments joined by spaces, so argument
/// boundaries are already gone here. Long options start their own line, and an
/// argument that is a complete JSON object or array, such as an Agent CLI's
/// `--settings {...}`, is re-indented keeping its key order and escapes. Text
/// that is not valid JSON is shown unchanged; copying uses the raw command.
enum CommandLineDisplayFormatter {
    static let indentUnit = "  "
    /// Characters the bracket matcher may examine in total. Every unmatched
    /// `{` or `[` rescans the rest of the line, so pathological input would
    /// otherwise cost quadratic time inside a modal dialog.
    static let scanBudget = 1_000_000

    static func format(_ commandLine: String) -> CommandLineDisplay {
        var builder = LineBuilder()
        var indent = ""
        for (index, piece) in pieces(of: Array(commandLine)).enumerated() {
            let separated = index > 0 && !piece.isAttached
            switch piece {
            case let .word(word, _):
                if separated, word.hasPrefix("--"), isOption(word) {
                    indent = indentUnit
                    builder.startLine(indent: indent)
                } else if separated {
                    builder.append(" ", .text)
                }
                appendWord(word, to: &builder)
            case let .json(json, _):
                if separated { builder.append(" ", .text) }
                appendJSON(json, indent: indent, to: &builder)
            }
        }
        return CommandLineDisplay(lines: builder.finish())
    }

    // MARK: - Splitting

    private enum Piece {
        case word(String, attached: Bool)
        case json(String, attached: Bool)

        /// No whitespace between this piece and the previous one, as in `--settings={...}`.
        var isAttached: Bool {
            switch self {
            case let .word(_, attached), let .json(_, attached): attached
            }
        }
    }

    private static func pieces(of characters: [Character]) -> [Piece] {
        var pieces: [Piece] = []
        var word = ""
        var wordAttached = false
        var followsWhitespace = true
        var budget = scanBudget
        var index = 0

        func flushWord() {
            guard !word.isEmpty else { return }
            pieces.append(.word(word, attached: wordAttached))
            word = ""
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                flushWord()
                followsWhitespace = true
                index += 1
                continue
            }
            if let end = jsonEnd(in: characters, from: index, budget: &budget) {
                flushWord()
                pieces.append(.json(String(characters[index...end]), attached: !followsWhitespace))
                followsWhitespace = false
                index = end + 1
                continue
            }
            if word.isEmpty { wordAttached = !followsWhitespace }
            word.append(character)
            followsWhitespace = false
            index += 1
        }
        flushWord()
        return pieces
    }

    /// End index of a JSON object or array starting at `start`, if the text
    /// there is one whole argument: it begins after whitespace, `=` or a quote
    /// and ends before whitespace or a quote.
    private static func jsonEnd(in characters: [Character], from start: Int, budget: inout Int) -> Int? {
        guard characters[start] == "{" || characters[start] == "[" else { return nil }
        if start > 0, !isJSONPrefixBoundary(characters[start - 1]) { return nil }
        guard let end = matchingBracket(in: characters, from: start, budget: &budget) else { return nil }
        if end + 1 < characters.count, !isJSONSuffixBoundary(characters[end + 1]) { return nil }
        let candidate = String(characters[start...end])
        guard (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil else { return nil }
        return end
    }

    private static func isJSONPrefixBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character == "=" || character == "'" || character == "\""
    }

    private static func isJSONSuffixBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character == "'" || character == "\""
    }

    private static func matchingBracket(in characters: [Character], from start: Int, budget: inout Int) -> Int? {
        var expected: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < characters.count {
            guard budget > 0 else { return nil }
            budget -= 1
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": expected.append("}")
                case "[": expected.append("]")
                case "}", "]":
                    guard expected.last == character else { return nil }
                    expected.removeLast()
                    if expected.isEmpty { return index }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Rendering

    private static func isOption(_ word: String) -> Bool {
        let name = word.drop { $0 == "-" }
        let dashes = word.count - name.count
        return (dashes == 1 || dashes == 2) && name.first?.isLetter == true
    }

    private static func appendWord(_ word: String, to builder: inout LineBuilder) {
        guard isOption(word) else {
            builder.append(word, .text)
            return
        }
        if let equals = word.firstIndex(of: "=") {
            builder.append(String(word[..<equals]), .option)
            builder.append(String(word[equals...]), .text)
        } else {
            builder.append(word, .option)
        }
    }

    private enum JSONToken {
        case open(Character)
        case close(Character)
        case comma
        case colon
        case string(String)
        case scalar(String)
    }

    private static func appendJSON(_ json: String, indent base: String, to builder: inout LineBuilder) {
        let tokens = jsonTokens(Array(json))
        var depth = 0
        var index = 0
        func lineIndent() -> String { base + String(repeating: indentUnit, count: depth) }

        while index < tokens.count {
            switch tokens[index] {
            case let .open(bracket):
                if index + 1 < tokens.count, case let .close(closing) = tokens[index + 1] {
                    builder.append("\(bracket)\(closing)", .jsonPunctuation)
                    index += 2
                    continue
                }
                builder.append(String(bracket), .jsonPunctuation)
                depth += 1
                builder.startLine(indent: lineIndent())
            case let .close(bracket):
                depth -= 1
                builder.startLine(indent: lineIndent())
                builder.append(String(bracket), .jsonPunctuation)
            case .comma:
                builder.append(",", .jsonPunctuation)
                builder.startLine(indent: lineIndent())
            case .colon:
                builder.append(":", .jsonPunctuation)
                builder.append(" ", .text)
            case let .string(literal):
                var isKey = false
                if index + 1 < tokens.count, case .colon = tokens[index + 1] { isKey = true }
                builder.append(literal, isKey ? .jsonKey : .jsonString)
            case let .scalar(literal):
                let isNumber = literal.first.map { $0 == "-" || $0.isNumber } ?? false
                builder.append(literal, isNumber ? .jsonNumber : .jsonLiteral)
            }
            index += 1
        }
    }

    /// Tokens of text already validated as JSON; strings keep their original escapes.
    private static func jsonTokens(_ characters: [Character]) -> [JSONToken] {
        var tokens: [JSONToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "{", "[":
                tokens.append(.open(character))
                index += 1
            case "}", "]":
                tokens.append(.close(character))
                index += 1
            case ",":
                tokens.append(.comma)
                index += 1
            case ":":
                tokens.append(.colon)
                index += 1
            case "\"":
                var end = index + 1
                var escaped = false
                while end < characters.count {
                    if escaped {
                        escaped = false
                    } else if characters[end] == "\\" {
                        escaped = true
                    } else if characters[end] == "\"" {
                        break
                    }
                    end += 1
                }
                tokens.append(.string(String(characters[index...min(end, characters.count - 1)])))
                index = end + 1
            case _ where character.isWhitespace:
                index += 1
            default:
                var end = index
                while end < characters.count, !characters[end].isWhitespace, !",:[]{}\"".contains(characters[end]) {
                    end += 1
                }
                tokens.append(.scalar(String(characters[index..<end])))
                index = end
            }
        }
        return tokens
    }
}

/// Accumulates runs line by line, merging neighbors with the same role.
private struct LineBuilder {
    private var lines: [[CommandLineDisplay.Run]] = []
    private var line: [CommandLineDisplay.Run] = []
    /// The run still being extended. Appending to it in place keeps a long
    /// line of same-role words linear instead of copying the run per word.
    private var pending = ""
    private var pendingRole = CommandLineDisplay.Role.text

    mutating func startLine(indent: String) {
        flushRun()
        lines.append(line)
        line = []
        append(indent, .text)
    }

    mutating func append(_ text: String, _ role: CommandLineDisplay.Role) {
        guard !text.isEmpty else { return }
        if role != pendingRole {
            flushRun()
            pendingRole = role
        }
        pending += text
    }

    mutating func finish() -> [[CommandLineDisplay.Run]] {
        flushRun()
        return lines + [line]
    }

    private mutating func flushRun() {
        guard !pending.isEmpty else { return }
        line.append(CommandLineDisplay.Run(text: pending, role: pendingRole))
        pending = ""
    }
}
