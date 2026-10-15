import Foundation

/// Identifies content that participates in the shared editor tab order.
enum EditorTabItem: Hashable, Identifiable {
    case document(UUID)
    case terminal(UUID)
    case media(UUID)
    case database(UUID?)
    case databaseQuery(profileID: UUID, queryID: UUID)
    case databaseOverview
    case repositoryDiff
    case agentConversation

    var id: Self { self }

    var isDatabaseTab: Bool {
        switch self {
        case .database, .databaseQuery, .databaseOverview: true
        default: false
        }
    }
}
