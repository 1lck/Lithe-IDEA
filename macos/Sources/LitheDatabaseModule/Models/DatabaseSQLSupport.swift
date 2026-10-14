import Foundation

package enum DatabaseWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case data
    case sql
    case structure
    case history

    package var id: String { rawValue }
}

package enum DatabaseSensitiveFieldMasker {
    package static func mask(rows: [DatabaseRow], enabled: Bool, patterns: [String]) -> [DatabaseRow] {
        guard enabled else { return rows }
        let normalizedPatterns = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedPatterns.isEmpty else { return rows }
        return rows.map { row in
            row.reduce(into: DatabaseRow()) { masked, entry in
                let (column, value) = entry
                let normalizedColumn = column.lowercased()
                if normalizedPatterns.contains(where: { normalizedColumn.contains($0) }) {
                    masked[column] = value == .null ? .null : .string("******")
                } else {
                    masked[column] = value
                }
            }
        }
    }
}

package enum DatabaseSQLStatementKind: String, Codable, Equatable, Sendable {
    case query
    case mutation
    case definition
    case transaction
    case batch
    case unknown

    package var usesQueryEndpoint: Bool {
        self == .query
    }
}

package struct DatabaseSQLAnalysis: Equatable, Sendable {
    package let kind: DatabaseSQLStatementKind
    package let statementCount: Int
    package let requiresConfirmation: Bool
    package let warning: String?
    package let statements: [String]

    package var canExecute: Bool { !statements.isEmpty || statementCount == 1 }

    package init(
        kind: DatabaseSQLStatementKind,
        statementCount: Int,
        requiresConfirmation: Bool,
        warning: String?,
        statements: [String] = []
    ) {
        self.kind = kind
        self.statementCount = statementCount
        self.requiresConfirmation = requiresConfirmation
        self.warning = warning
        self.statements = statements
    }
}

package enum DatabaseSQLExecutionScope: Equatable, Sendable {
    case all
    case selection(String)
}

package struct DatabaseSQLTab: Identifiable, Equatable, Sendable {
    package let id: UUID
    package var title: String
    package var sql: String
    package var result: DatabaseQueryResult?
    package var resultColumns: [String]
    package var rowsAffected: UInt64?
    package var execution: DatabaseSQLExecution?
    package var errorMessage: String?
    package var isRunning: Bool
    package var statementExecutions: [DatabaseSQLStatementExecution] = []
    package var outputHiddenThroughExecutionID: UUID?

    package init(id: UUID = UUID(), title: String, sql: String = "") {
        self.id = id
        self.title = title
        self.sql = sql
        result = nil
        resultColumns = []
        rowsAffected = nil
        execution = nil
        errorMessage = nil
        isRunning = false
    }
}

/// Runtime output stays with its console, never in connection preferences.
package struct DatabaseSQLStatementExecution: Equatable, Identifiable, Sendable {
    package let id: UUID
    package let sql: String
    // Rendering reference follows edits outside this statement; `sql` remains the actual executed text.
    package var sourceSQL: String
    package var sourceRange: NSRange?
    package let startedAt: Date
    package let batchStartedAt: Date
    package let durationMilliseconds: Int
    package var result: DatabaseQueryResult?
    package let rowsReturned: Int?
    package let rowsAffected: UInt64?
    package let errorMessage: String?
}

package struct DatabaseSQLExecution: Equatable, Sendable {
    package let startedAt: Date
    package let durationMilliseconds: Int
    package let rowsReturned: Int?
    package let rowsAffected: UInt64?
    package let truncated: Bool
}

/// Kept separately from a connection profile so neither passwords nor result
/// data ever enter preferences. The SQL text is intentionally retained for a
/// familiar query-history workflow.
package struct DatabaseSQLHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let profileID: UUID
    package let sql: String
    package let kind: DatabaseSQLStatementKind
    package let executedAt: Date
    package let durationMilliseconds: Int
    package let rowsReturned: Int?
    package let rowsAffected: UInt64?

    package init(
        id: UUID = UUID(),
        profileID: UUID,
        sql: String,
        kind: DatabaseSQLStatementKind,
        executedAt: Date,
        durationMilliseconds: Int,
        rowsReturned: Int? = nil,
        rowsAffected: UInt64? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.sql = sql
        self.kind = kind
        self.executedAt = executedAt
        self.durationMilliseconds = durationMilliseconds
        self.rowsReturned = rowsReturned
        self.rowsAffected = rowsAffected
    }
}

package enum DatabaseSQLAnalyzer {
    package static func analyze(_ sql: String) -> DatabaseSQLAnalysis {
        let statements = DatabaseSQLLexing.statements(in: sql)
        guard !statements.isEmpty else {
            return DatabaseSQLAnalysis(
                kind: .unknown,
                statementCount: statements.count,
                requiresConfirmation: false,
                warning: "Enter a SQL statement.",
                statements: statements
            )
        }

        let analyses = statements.map(analyzeSingle)
        let kinds = analyses.map(\.kind)
        let kind = statements.count > 1 ? .batch : kinds[0]
        return DatabaseSQLAnalysis(
            kind: kind,
            statementCount: statements.count,
            requiresConfirmation: analyses.contains(where: \.requiresConfirmation),
            warning: warning(for: analyses),
            statements: statements
        )
    }

    private static func warning(for analyses: [DatabaseSQLAnalysis]) -> String? {
        let warnings = analyses.compactMap(\.warning)
        return warnings.first(where: { !$0.contains("not recognized") }) ?? warnings.first
    }

    private static func analyzeSingle(_ statement: String) -> DatabaseSQLAnalysis {
        let tokens = DatabaseSQLLexing.keywords(in: statement)
        guard let first = tokens.first else {
            return DatabaseSQLAnalysis(kind: .unknown, statementCount: 0, requiresConfirmation: false, warning: "Enter a SQL statement.", statements: [])
        }

        let kind: DatabaseSQLStatementKind
        switch first {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "PRAGMA", "VALUES": kind = .query
        case "WITH":
            let writeKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE"]
            kind = tokens.contains(where: writeKeywords.contains) ? .mutation : .query
        case "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE": kind = .mutation
        case "CREATE", "ALTER", "DROP", "TRUNCATE", "VACUUM", "ANALYZE", "GRANT", "REVOKE": kind = .definition
        case "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "SET": kind = .transaction
        default: kind = .unknown
        }

        let isUnqualifiedWrite = (tokens.contains("UPDATE") || tokens.contains("DELETE")) && !tokens.contains("WHERE")
        let isDestructive = tokens.contains("DROP") || tokens.contains("TRUNCATE")
        let isUnknownStatement = kind == .unknown
        let requiresConfirmation = isUnqualifiedWrite || isDestructive
        let warning: String?
        if isUnqualifiedWrite {
            warning = "This UPDATE or DELETE has no WHERE clause and can affect every row."
        } else if isDestructive {
            warning = "This statement can permanently remove database objects or data."
        } else if isUnknownStatement {
            warning = "This statement type is not recognized locally; the database will validate it."
        } else {
            warning = nil
        }
        return DatabaseSQLAnalysis(kind: kind, statementCount: 1, requiresConfirmation: requiresConfirmation, warning: warning, statements: [statement])
    }
}

package enum DatabaseSQLFormatter {
    package static func format(_ sql: String) -> String {
        // ponytail: Top-level clause layout only; use a dialect formatter when a provider exposes one.
        // ponytail: Backslash escaping depends on dialect AND session modes; keep ambiguous scripts verbatim until a provider formatter supplies that context.
        if sql.contains("\\") || sql.range(of: #"\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$"#, options: .regularExpression) != nil { return sql }
        // JetBrains SQL Code Style: preserve word case, SELECT elements on a new line, 4-space indent.
        let selectIndent = "    "
        let clauses: Set<String> = [ "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "RETURNING", "SET", "VALUES", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS"]
        // SQL delimiters are scalar boundaries; a combining mark may share a Swift Character with its opening quote.
        let source = sql.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { Character(String($0)) }
        var output = ""
        var word = ""
        var needsSpace = false
        var index = 0
        var depth = 0
        var previousWord = ""
        var followsLineComment = false

        func appendWord() {
            guard !word.isEmpty else { return }
            let keyword = word.uppercased()
            let qualified = output.hasSuffix(".")
            let joinModifier = ["LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS"].contains(previousWord)
            if depth == 0, !qualified, keyword == "FROM", !followsLineComment, output.hasSuffix("\n") {
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                needsSpace = true
            }
            if depth == 0, !qualified, clauses.contains(keyword), !output.isEmpty,
               !(joinModifier && (keyword == "JOIN" || keyword == "OUTER")) {
                output = output.trimmingCharacters(in: .whitespaces)
                if !output.hasSuffix("\n") { output.append("\n") }
            } else if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
            output.append(word)
            previousWord = keyword
            followsLineComment = false
            word = ""
            needsSpace = true
            if depth == 0, !qualified, keyword == "SELECT" {
                output.append("\n" + selectIndent)
                needsSpace = false
            }
        }

        while index < source.count {
            let character = source[index]
            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                word.append(character)
                index += 1
                continue
            }
            appendWord()
            if character.isWhitespace {
                if character == "\n", !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix("\n" + selectIndent) { output.append("\n") }
                needsSpace = !output.isEmpty && !output.hasSuffix("\n") && !output.hasSuffix(" ")
                index += 1
                continue
            }
            if character == "#" || (character == "-" && index + 1 < source.count && source[index + 1] == "-") {
                if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                output.append(character == "#" ? "#" : "--")
                index += character == "#" ? 1 : 2
                while index < source.count {
                    output.append(source[index])
                    if source[index] == "\n" { index += 1; break }
                    index += 1
                }
                needsSpace = false
                followsLineComment = true
                continue
            }
            if character == "/", index + 1 < source.count, source[index + 1] == "*" {
                if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                output.append("/*")
                index += 2
                var commentDepth = 1
                while index < source.count {
                    let commentCharacter = source[index]
                    output.append(commentCharacter)
                    if commentCharacter == "*", index + 1 < source.count, source[index + 1] == "/" {
                        output.append("/")
                        index += 2
                        commentDepth -= 1
                        if commentDepth == 0 { break }
                        continue
                    }
                    if commentCharacter == "/", index + 1 < source.count, source[index + 1] == "*" {
                        output.append("*")
                        index += 2
                        commentDepth += 1
                        continue
                    }
                    index += 1
                }
                needsSpace = true
                continue
            }
            if character == "'" || character == "\"" || character == "`" || character == "[" {
                // Preserve adjacent literal prefixes (E'...', X'...') and qualified quoted identifiers.
                if index > 0, source[index - 1].isWhitespace, needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                let quote: Character = character == "[" ? "]" : character
                output.append(character)
                index += 1
                while index < source.count {
                    let quoted = source[index]
                    output.append(quoted)
                    index += 1
                    if quoted == "\\", index < source.count {
                        output.append(source[index]); index += 1; continue
                    }
                    if quoted == quote {
                        if index < source.count, source[index] == quote {
                            output.append(source[index])
                            index += 1
                        } else {
                            break
                        }
                    }
                }
                needsSpace = true
                continue
            }
            if character == ";" {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append(";\n")
                previousWord = ""
                needsSpace = false
            } else if character == "," {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append(", ")
                needsSpace = false
            } else if character == "(" {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append("(")
                depth += 1
                needsSpace = false
            } else if character == ")" {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append(")")
                depth = max(0, depth - 1)
                needsSpace = true
            } else {
                // Keep adjacent punctuation intact: decimals, qualified names, casts and compound operators.
                if index > 0, source[index - 1].isWhitespace, !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix(" ") { output.append(" ") }
                output.append(character)
                needsSpace = false
            }
            index += 1
        }
        appendWord()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DatabaseSQLLexing {
    package static func keywords(in sql: String) -> [String] {
        sanitized(sql).split { !$0.isLetter && $0 != "_" }.map { String($0).uppercased() }
    }

    package static func statements(in sql: String) -> [String] {
        let characters = sql.unicodeScalars.map { Character(String($0)) }
        var statements: [String] = []
        var current = ""
        var index = 0
        var quote: Character?
        var lineComment = false
        var blockComment = false

        func appendCurrentStatement() {
            guard !sanitized(current).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            statements.append(current)
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if lineComment {
                current.append(character)
                if character == "\n" { lineComment = false }
                index += 1
                continue
            }
            if blockComment {
                current.append(character)
                if character == "*", next == "/" {
                    current.append("/")
                    blockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if let activeQuote = quote {
                current.append(character)
                if character == "\\", next != nil {
                    current.append(next!)
                    index += 2
                    continue
                }
                if character == activeQuote {
                    if next == activeQuote { index += 1; current.append(activeQuote) }
                    else { quote = nil }
                }
                index += 1; continue
            }
            if character == "-", next == "-" { lineComment = true; current.append(character); current.append(next!); index += 2; continue }
            if character == "/", next == "*" { blockComment = true; current.append(character); current.append(next!); index += 2; continue }
            if character == "'" || character == "\"" || character == "`" { quote = character; current.append(character); index += 1; continue }
            if character == ";" {
                appendCurrentStatement()
                current = ""; index += 1; continue
            }
            current.append(character)
            index += 1
        }
        appendCurrentStatement()
        return statements
    }

    private static func sanitized(_ sql: String) -> String {
        let characters = sql.unicodeScalars.map { Character(String($0)) }
        var output = ""
        var index = 0
        var quote: Character?
        var lineComment = false
        var blockComment = false
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if lineComment {
                if character == "\n" { lineComment = false; output.append(" ") }
                index += 1
                continue
            }
            if blockComment {
                if character == "*", next == "/" { blockComment = false; index += 2; output.append(" ") }
                else { index += 1 }
                continue
            }
            if let activeQuote = quote {
                if character == "\\", next != nil {
                    output.append("  ")
                    index += 2
                    continue
                }
                if character == activeQuote {
                    if next == activeQuote { index += 2 }
                    else { quote = nil; index += 1 }
                } else {
                    index += 1
                }
                output.append(" ")
                continue
            }
            if character == "-", next == "-" { lineComment = true; index += 2; output.append(" "); continue }
            if character == "/", next == "*" { blockComment = true; index += 2; output.append(" "); continue }
            if character == "'" || character == "\"" || character == "`" { quote = character; index += 1; output.append(" "); continue }
            output.append(character)
            index += 1
        }
        return output
    }
}
