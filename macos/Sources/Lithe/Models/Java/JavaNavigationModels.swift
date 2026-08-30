import Foundation
import LitheCoreContracts

struct EditorCaret: Equatable {
    let url: URL
    let line: Int
    let utf16Column: Int
}

struct EditorNavigationTarget: Equatable, Identifiable {
    let id = UUID()
    let url: URL
    let line: Int
    let utf16Column: Int
    /// 整行选中目标行（Go to Line 行为）；符号与查找导航保持零长度光标。
    var selectsWholeLine: Bool = false
}

struct LanguageNavigationLocation: Identifiable, Hashable, Sendable {
    let url: URL
    let line: Int
    let utf16Column: Int
    let isReadOnly: Bool
    let displayPath: String?

    init(
        url: URL,
        line: Int,
        utf16Column: Int,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        self.url = url
        self.line = line
        self.utf16Column = utf16Column
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
    }

    var id: String { "\(url.path):\(line):\(utf16Column)" }

    var displayName: String { displayPath?.split(separator: "/").last.map(String.init) ?? url.lastPathComponent }
}

struct JavaWorkspaceSymbol: Identifiable, Hashable, Sendable {
    let name: String
    let containerName: String?
    let url: URL
    let line: Int
    let utf16Column: Int
    let kind: Int

    var id: String { "\(url.path):\(line):\(utf16Column):\(name):\(kind)" }

    var isType: Bool {
        [5, 10, 11, 23].contains(kind)
    }
}

struct JavaCodeVisionHint: Identifiable, Hashable {
    let line: Int
    let utf16Column: Int
    let symbol: String
    let usageCount: Int
    let implementationCount: Int
    let authorName: String?

    var id: String { "\(line):\(utf16Column):\(symbol)" }
}

enum JavaFoldKind: String, Hashable {
    case imports
    case type
    case method
    case block
    case comment
}

struct JavaFoldRegion: Identifiable, Hashable {
    let kind: JavaFoldKind
    let startLine: Int
    let endLine: Int
    let hiddenRange: NSRange

    var id: String { "\(kind.rawValue):\(startLine):\(endLine)" }
}

typealias JavaImplementationDirection = JavaNavigationDirection
typealias JavaImplementationRelation = JavaNavigationRelation

struct JavaImplementationMarker: Identifiable, Hashable, Sendable {
    let line: Int
    let utf16Column: Int
    let implementationCount: Int
    let direction: JavaImplementationDirection
    let relation: JavaImplementationRelation

    init(
        line: Int,
        utf16Column: Int,
        isType: Bool,
        implementationCount: Int = 0
    ) {
        self.init(
            line: line,
            utf16Column: utf16Column,
            implementationCount: implementationCount,
            direction: isType ? .down : .up,
            relation: isType ? .interface : .inheritance
        )
    }

    init(
        line: Int,
        utf16Column: Int,
        implementationCount: Int,
        direction: JavaImplementationDirection,
        relation: JavaImplementationRelation = .inheritance
    ) {
        self.line = line
        self.utf16Column = utf16Column
        self.implementationCount = implementationCount
        self.direction = direction
        self.relation = relation
    }

    init(_ marker: JavaNavigationMarker) {
        self.init(
            line: marker.line,
            utf16Column: marker.utf16Column,
            implementationCount: marker.implementationCount,
            direction: marker.direction,
            relation: marker.relation
        )
    }

    var sharedMarker: JavaNavigationMarker {
        JavaNavigationMarker(
            line: line,
            utf16Column: utf16Column,
            implementationCount: implementationCount,
            direction: direction,
            relation: relation
        )
    }

    var isType: Bool { direction == .down }

    var id: String { "\(line):\(utf16Column):\(direction.rawValue):\(relation.rawValue)" }
}

enum LanguageNavigationResultKind {
    case definitions
    case references
    case implementations

    var title: String {
        switch self {
        case .definitions: "Definitions"
        case .references: "Usages"
        case .implementations: "Implementations"
        }
    }
}

enum LanguageNavigationState {
    case idle
    case loading(operationID: UUID, providerID: String, kind: LanguageNavigationResultKind)
    case results(
        providerID: String?,
        kind: LanguageNavigationResultKind,
        locations: [LanguageNavigationLocation]
    )

    var providerID: String? {
        switch self {
        case .idle: nil
        case .loading(_, let providerID, _): providerID
        case .results(let providerID, _, _): providerID
        }
    }

    var kind: LanguageNavigationResultKind {
        switch self {
        case .idle: .definitions
        case .loading(_, _, let kind),
             .results(_, let kind, _): kind
        }
    }

    var locations: [LanguageNavigationLocation] {
        guard case .results(_, _, let locations) = self else { return [] }
        return locations
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    func owns(operationID: UUID) -> Bool {
        guard case .loading(let ownedID, _, _) = self else { return false }
        return ownedID == operationID
    }
}
