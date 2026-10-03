import Foundation

/// Identifies content that participates in the shared editor tab order.
enum EditorTabItem: Hashable, Identifiable {
    case document(UUID)
    case terminal(UUID)
    case media(UUID)
    case repositoryDiff

    var id: Self { self }
}
