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

struct JavaNavigationLocation: Identifiable, Hashable, Sendable {
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

struct JavaInlayHint: Identifiable, Hashable {
    let line: Int
    let utf16Column: Int
    let label: String

    var id: String { "\(line):\(utf16Column):\(label)" }
}

enum JavaImplementationDirection: String, Hashable, Sendable {
    case down
    case up
}

struct JavaImplementationMarker: Identifiable, Hashable, Sendable {
    let line: Int
    let utf16Column: Int
    let implementationCount: Int
    let direction: JavaImplementationDirection

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
            direction: isType ? .down : .up
        )
    }

    init(
        line: Int,
        utf16Column: Int,
        implementationCount: Int,
        direction: JavaImplementationDirection
    ) {
        self.line = line
        self.utf16Column = utf16Column
        self.implementationCount = implementationCount
        self.direction = direction
    }

    var isType: Bool { direction == .down }

    var id: String { "\(line):\(utf16Column):\(direction.rawValue)" }
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
