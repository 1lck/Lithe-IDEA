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

enum JavaNavigationResultKind {
    case definitions
    case references

    var title: String {
        switch self {
        case .definitions: "Definitions"
        case .references: "Usages"
        }
    }
}
