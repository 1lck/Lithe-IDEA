import Foundation
import LitheCoreContracts

enum SidebarDestination: String, CaseIterable, Identifiable {
    case project
    case changes
    case search
    case database

    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: "Project"
        case .changes: "Changes"
        case .search: "Search"
        case .database: "Database"
        }
    }
    var systemImage: String {
        switch self {
        case .project: "folder"
        case .changes: "slider.horizontal.3"
        case .search: "magnifyingglass"
        case .database: "cylinder.split.1x2"
        }
    }
    var ideaAssetPath: String {
        switch self {
        case .project: "toolwindows/toolWindowProject.svg"
        case .changes: "toolwindows/toolWindowCommit.svg"
        case .search: "toolwindows/toolWindowFind.svg"
        case .database: "toolwindows/toolWindowDatabase.svg"
        }
    }
}

typealias ProjectItemEditKind = LitheCoreContracts.ProjectItemEditKind
typealias ProjectItemEditRequest = LitheCoreContracts.ProjectItemEditRequest
typealias ProjectItemDeletionRequest = LitheCoreContracts.ProjectItemDeletionRequest

enum FindNotificationKeys {
    static let query = "query"
    static let direction = "direction"
}

extension Notification.Name {
    static let litheFindQueryChanged = Notification.Name("litheFindQueryChanged")
    static let litheFindNavigate = Notification.Name("litheFindNavigate")
    static let litheFindDismiss = Notification.Name("litheFindDismiss")
}
