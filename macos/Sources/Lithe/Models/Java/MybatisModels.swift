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
    let xmlURL: URL
    let xmlLine: Int
    let xmlColumn: Int
}

struct MybatisIndexResult: Sendable {
    let statements: [MybatisStatement]

    static let empty = MybatisIndexResult(statements: [])
}
