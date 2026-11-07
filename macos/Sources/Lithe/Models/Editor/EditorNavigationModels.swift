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
    /// Select the whole target line on arrival (Go to Line); symbol and find
    /// navigation keep a zero-length caret.
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
