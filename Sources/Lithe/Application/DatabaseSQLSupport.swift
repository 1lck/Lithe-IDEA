import Foundation

enum DatabaseSensitiveFieldMasker {
    static func mask(rows: [DatabaseRow], enabled: Bool, patterns: [String]) -> [DatabaseRow] {
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

enum DatabaseSQLStatementKind: String, Codable, Equatable, Sendable {
    case query
    case mutation
    case definition
    case transaction
    case unknown

    var usesQueryEndpoint: Bool {
        self == .query
    }
}

struct DatabaseSQLAnalysis: Equatable, Sendable {
    let kind: DatabaseSQLStatementKind
    let statementCount: Int
    let requiresConfirmation: Bool
    let warning: String?

    var canExecute: Bool { statementCount == 1 }
}

struct DatabaseSQLTab: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var sql: String
    var result: DatabaseQueryResult?
    var resultColumns: [String]
    var rowsAffected: UInt64?
    var execution: DatabaseSQLExecution?
    var errorMessage: String?
    var isRunning: Bool

    init(id: UUID = UUID(), title: String, sql: String = "") {
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

struct DatabaseSQLExecution: Equatable, Sendable {
    let startedAt: Date
    let durationMilliseconds: Int
    let rowsReturned: Int?
    let rowsAffected: UInt64?
    let truncated: Bool
}

/// Kept separately from a connection profile so neither passwords nor result
/// data ever enter preferences. The SQL text is intentionally retained for a
/// familiar query-history workflow.
struct DatabaseSQLHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let sql: String
    let kind: DatabaseSQLStatementKind
    let executedAt: Date
    let durationMilliseconds: Int
    let rowsReturned: Int?
    let rowsAffected: UInt64?

    init(
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

enum DatabaseSQLAnalyzer {
    static func analyze(_ sql: String) -> DatabaseSQLAnalysis {
        let statements = DatabaseSQLLexing.statements(in: sql)
        guard statements.count == 1, let statement = statements.first else {
            return DatabaseSQLAnalysis(
                kind: .unknown,
                statementCount: statements.count,
                requiresConfirmation: false,
                warning: statements.isEmpty ? "Enter a SQL statement." : "Run one SQL statement at a time."
            )
        }

        let tokens = DatabaseSQLLexing.keywords(in: statement)
        guard let first = tokens.first else {
            return DatabaseSQLAnalysis(kind: .unknown, statementCount: 0, requiresConfirmation: false, warning: "Enter a SQL statement.")
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
        return DatabaseSQLAnalysis(kind: kind, statementCount: 1, requiresConfirmation: requiresConfirmation, warning: warning)
    }
}

enum DatabaseSQLFormatter {
    static func format(_ sql: String) -> String {
        let keywords = DatabaseSQLLexing.formatKeywords
        let source = Array(sql.trimmingCharacters(in: .whitespacesAndNewlines))
        var output = ""
        var word = ""
        var needsSpace = false
        var index = 0

        func appendWord() {
            guard !word.isEmpty else { return }
            if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
            output.append(keywords.contains(word.uppercased()) ? word.uppercased() : word)
            word = ""
            needsSpace = true
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
                needsSpace = !output.isEmpty && !output.hasSuffix("\n") && !output.hasSuffix(" ")
                index += 1
                continue
            }
            if character == "-", index + 1 < source.count, source[index + 1] == "-" {
                if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                output.append("--")
                index += 2
                while index < source.count {
                    output.append(source[index])
                    if source[index] == "\n" { index += 1; break }
                    index += 1
                }
                needsSpace = false
                continue
            }
            if character == "/", index + 1 < source.count, source[index + 1] == "*" {
                if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                output.append("/*")
                index += 2
                while index < source.count {
                    let commentCharacter = source[index]
                    output.append(commentCharacter)
                    if commentCharacter == "*", index + 1 < source.count, source[index + 1] == "/" {
                        output.append("/")
                        index += 2
                        break
                    }
                    index += 1
                }
                needsSpace = true
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                let quote = character
                output.append(character)
                index += 1
                while index < source.count {
                    let quoted = source[index]
                    output.append(quoted)
                    index += 1
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
                needsSpace = false
            } else if character == "," {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append(", ")
                needsSpace = false
            } else if character == "(" {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append("(")
                needsSpace = false
            } else if character == ")" {
                output = output.trimmingCharacters(in: .whitespaces)
                output.append(")")
                needsSpace = true
            } else {
                if needsSpace, !output.isEmpty, !output.hasSuffix("\n") { output.append(" ") }
                output.append(character)
                needsSpace = true
            }
            index += 1
        }
        appendWord()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DatabaseSQLLexing {
    static let formatKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "MERGE", "REPLACE",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "TABLE", "VIEW", "INDEX", "DATABASE", "SCHEMA", "TRIGGER",
        "PROCEDURE", "FUNCTION", "BEGIN", "COMMIT", "ROLLBACK", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
        "ON", "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "EXISTS", "BETWEEN", "LIKE", "DISTINCT",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "WITH", "RETURNING", "SET",
        "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "PRAGMA", "GRANT", "REVOKE", "VACUUM", "ANALYZE", "CASE",
        "WHEN", "THEN", "ELSE", "END", "ASC", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT"
    ]

    static func keywords(in sql: String) -> [String] {
        sanitized(sql).split { !$0.isLetter && $0 != "_" }.map { String($0).uppercased() }
    }

    static func statements(in sql: String) -> [String] {
        let characters = Array(sql)
        var statements: [String] = []
        var current = ""
        var index = 0
        var quote: Character?
        var lineComment = false
        var blockComment = false

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if lineComment {
                if character == "\n" { lineComment = false; current.append(" ") }
                index += 1; continue
            }
            if blockComment {
                if character == "*", next == "/" { blockComment = false; index += 2; current.append(" ") }
                else { index += 1 }
                continue
            }
            if let activeQuote = quote {
                current.append(" ")
                if character == activeQuote {
                    if next == activeQuote { index += 1; current.append(" ") }
                    else { quote = nil }
                }
                index += 1; continue
            }
            if character == "-", next == "-" { lineComment = true; index += 2; current.append(" "); continue }
            if character == "/", next == "*" { blockComment = true; index += 2; current.append(" "); continue }
            if character == "'" || character == "\"" || character == "`" { quote = character; current.append(" "); index += 1; continue }
            if character == ";" {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { statements.append(current) }
                current = ""; index += 1; continue
            }
            current.append(character)
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { statements.append(current) }
        return statements
    }

    private static func sanitized(_ sql: String) -> String {
        statements(in: sql).joined(separator: " ")
    }
}
