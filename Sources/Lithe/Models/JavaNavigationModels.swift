import Foundation

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
}

struct JavaNavigationLocation: Identifiable, Hashable {
    let url: URL
    let line: Int
    let utf16Column: Int

    var id: String { "\(url.path):\(line):\(utf16Column)" }
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

struct JavaInlayHint: Identifiable, Hashable {
    let line: Int
    let utf16Column: Int
    let label: String

    var id: String { "\(line):\(utf16Column):\(label)" }
}

struct JavaImplementationMarker: Identifiable, Hashable {
    let line: Int
    let utf16Column: Int
    let isType: Bool

    var id: String { "\(line):\(utf16Column):\(isType)" }
}

enum JavaNavigationResultKind {
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
