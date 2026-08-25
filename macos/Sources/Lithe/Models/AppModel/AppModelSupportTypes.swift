import Foundation
import LitheCoreContracts

enum SidebarDestination: String, CaseIterable, Identifiable {
    case project
    case changes
    case pullRequests
    case search
    case database

    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: "Project"
        case .changes: "Changes"
        case .pullRequests: "Pull Requests"
        case .search: "Search"
        case .database: "Database"
        }
    }
    var systemImage: String {
        switch self {
        case .project: "folder"
        case .changes: "slider.horizontal.3"
        case .pullRequests: "arrow.triangle.pull"
        case .search: "magnifyingglass"
        case .database: "cylinder.split.1x2"
        }
    }
    var ideaAssetPath: String? {
        switch self {
        case .project: "toolwindows/toolWindowProject.svg"
        case .changes: "toolwindows/toolWindowCommit.svg"
        case .pullRequests: nil
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

struct ProjectTreeRevealRequest: Equatable {
    let id = UUID()
    let fileURL: URL
    let isDirectory: Bool
}

enum ProjectTreeLocator {
    static func matchingURL(for url: URL, among projectFiles: [URL]) -> URL? {
        let standardizedPath = url.standardizedFileURL.path
        return projectFiles.first(where: {
            $0.standardizedFileURL.path == standardizedPath
        })
    }

    static func matchingURL(for url: URL, in node: FileNode) -> URL? {
        let standardizedPath = url.standardizedFileURL.path
        if node.url.standardizedFileURL.path == standardizedPath {
            return node.url
        }
        if node.collapsedAncestorPaths.contains(where: {
            URL(fileURLWithPath: $0).standardizedFileURL.path == standardizedPath
        }) {
            return node.url
        }
        for child in node.children ?? [] {
            if let match = matchingURL(for: url, in: child) {
                return match
            }
        }
        return nil
    }

    static func expandedDirectoryPaths(
        for itemURL: URL,
        rootURL: URL,
        includeItem: Bool = false
    ) -> Set<String> {
        let root = rootURL.standardizedFileURL
        let item = itemURL.standardizedFileURL
        var directory = includeItem ? item : item.deletingLastPathComponent()
        var paths = Set([root.path])
        while directory.path != root.path, directory.path.hasPrefix(root.path + "/") {
            paths.insert(directory.path)
            directory.deleteLastPathComponent()
        }
        return paths
    }
}
