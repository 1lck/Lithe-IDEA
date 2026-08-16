import Foundation

struct SpringProperty: Identifiable, Hashable, Sendable {
    let name: String
    let typeName: String?
    let documentation: String?
    let defaultValue: String?
    let sourceURL: URL?
    let sourceLine: Int?
    let sourceColumn: Int?

    var id: String { name }
}

struct SpringConfigurationValue: Identifiable, Hashable, Sendable {
    let key: String
    let value: String
    let url: URL
    let line: Int
    let column: Int
    let profile: String?
    let overridesBaseValue: Bool
    let targetURL: URL?
    let targetLine: Int?
    let targetColumn: Int?

    var id: String { "\(url.path):\(line):\(key)" }
}

struct SpringPropertyReference: Identifiable, Hashable, Sendable {
    let key: String
    let url: URL
    let line: Int
    let column: Int

    var id: String { "\(url.path):\(line):\(column):\(key)" }
}

struct SpringDiagnostic: Identifiable, Hashable, Sendable {
    let url: URL
    let line: Int
    let column: Int
    let severity: String
    let message: String

    var id: String { "\(url.path):\(line):\(column):\(message)" }
}

struct SpringBean: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let typeName: String
    let url: URL
    let line: Int
    let column: Int
    let kind: String
}

struct SpringInjection: Identifiable, Hashable, Sendable {
    let url: URL
    let line: Int
    let column: Int
    let typeName: String
    let qualifier: String?
    let beanIDs: [String]

    var id: String { "\(url.path):\(line):\(column):\(typeName)" }
}

struct SpringEndpoint: Identifiable, Hashable, Sendable {
    let id: String
    let httpMethods: [String]
    let route: String
    let controller: String
    let method: String
    let url: URL
    let line: Int
    let column: Int
}

struct SpringIndexResult: Sendable {
    let properties: [SpringProperty]
    let values: [SpringConfigurationValue]
    let propertyReferences: [SpringPropertyReference]
    let diagnostics: [SpringDiagnostic]
    let beans: [SpringBean]
    let injections: [SpringInjection]
    let endpoints: [SpringEndpoint]

    static let empty = SpringIndexResult(
        properties: [], values: [], propertyReferences: [], diagnostics: [], beans: [],
        injections: [], endpoints: []
    )
}
