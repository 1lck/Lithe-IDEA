import Foundation

struct MybatisStatement: Identifiable, Hashable, Sendable {
    let id: String
    let namespace: String
    let statementID: String
    let kind: String
    let javaURL: URL
    let javaLine: Int
    let javaColumn: Int
    let javaEndLine: Int
    let javaEndColumn: Int
    let xmlURL: URL
    let xmlLine: Int
    let xmlColumn: Int
    let xmlEndColumn: Int

    /// Zero-based caret hits the Java method name, not the return type or parameters.
    func matchesJavaName(line: Int, utf16Column: Int) -> Bool {
        MybatisIndexPaths.contains(
            line: line,
            utf16Column: utf16Column,
            symbolLine: javaLine,
            symbolColumn: javaColumn,
            symbolEndColumn: javaEndColumn
        )
    }

    /// Zero-based caret hits the XML statement `id` value.
    func matchesXmlId(line: Int, utf16Column: Int) -> Bool {
        MybatisIndexPaths.contains(
            line: line,
            utf16Column: utf16Column,
            symbolLine: xmlLine,
            symbolColumn: xmlColumn,
            symbolEndColumn: xmlEndColumn
        )
    }
}

struct MybatisIndexResult: Sendable {
    let statements: [MybatisStatement]

    static let empty = MybatisIndexResult(statements: [])
}

enum MybatisIndexPaths {
    static func matches(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "java" { return true }
        return ext == "xml" && url.lastPathComponent.lowercased() != "pom.xml"
    }

    static func contains(
        line: Int,
        utf16Column: Int,
        symbolLine: Int,
        symbolColumn: Int,
        symbolEndColumn: Int
    ) -> Bool {
        let caretLine = line + 1
        let caretColumn = utf16Column + 1
        return caretLine == symbolLine
            && caretColumn >= symbolColumn
            && caretColumn < symbolEndColumn
    }
}
