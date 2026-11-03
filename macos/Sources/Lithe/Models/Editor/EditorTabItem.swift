import Foundation

/// Identifies content that participates in the shared editor tab order.
enum EditorTabItem: Hashable, Identifiable {
    case document(UUID)
    case terminal(UUID)
    case media(UUID)
    case repositoryDiff(UUID)
    /// One Agent conversation tab. The UUID names the tab, not the session: a new
    /// tab exists before the Agent has created its session.
    case agentConversation(UUID)

    var id: Self { self }
}
