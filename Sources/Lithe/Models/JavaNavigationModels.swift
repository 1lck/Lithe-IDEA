import Foundation

struct EditorCaret: Equatable {
    let url: URL
    let line: Int
    let utf16Column: Int
}

struct EditorNavigationTarget: Equatable, Identifiable {
    let id = UUID()
    let url: URL
    let range: LanguageServerRange

    init(url: URL, range: LanguageServerRange) {
        self.url = url
        self.range = range
    }

    init(url: URL, line: Int, utf16Column: Int) {
        let position = LanguageServerPosition(
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        self.init(
            url: url,
            range: LanguageServerRange(start: position, end: position)
        )
    }

    var line: Int { range.start.line }
    var utf16Column: Int { range.start.utf16Column }
}

struct LanguageNavigationLocation: Identifiable, Hashable, Sendable {
    let url: URL
    let range: LanguageServerRange
    let isReadOnly: Bool
    let displayPath: String?

    init(
        url: URL,
        line: Int,
        utf16Column: Int,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        let position = LanguageServerPosition(
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        self.init(
            url: url,
            range: LanguageServerRange(start: position, end: position),
            isReadOnly: isReadOnly,
            displayPath: displayPath
        )
    }

    init(
        url: URL,
        range: LanguageServerRange,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        self.url = url
        self.range = range
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
    }

    var line: Int { range.start.line }
    var utf16Column: Int { range.start.utf16Column }

    var id: String {
        "\(url.path):\(range.start.line):\(range.start.utf16Column):\(range.end.line):\(range.end.utf16Column)"
    }

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

    var countLabel: String {
        switch self {
        case .definitions: "definitions"
        case .references: "usages"
        case .implementations: "implementations"
        }
    }

    var systemImage: String {
        switch self {
        case .definitions: "arrow.turn.down.right"
        case .references: "scope"
        case .implementations: "arrow.triangle.branch"
        }
    }
}
