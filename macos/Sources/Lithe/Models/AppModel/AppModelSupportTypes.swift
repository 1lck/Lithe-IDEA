import Foundation
import LitheCoreContracts
import LitheDebugModule

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case editor = "Editor"
    case keymap = "Keymap"
    case terminal = "Terminal"
    case lsp = "LSP"
    case ai = "AI & Commit"
    case updates = "Updates"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .editor: "textformat"
        case .keymap: "keyboard"
        case .terminal: "terminal"
        case .lsp: "server.rack"
        case .ai: "wand.and.stars"
        case .updates: "arrow.down.circle"
        }
    }
}

/// Product-level availability switches for integrations that require external
/// credentials or services. Keeping these switches in one place lets the UI
/// and application model disable an integration consistently without removing
/// its implementation, tests, or shared contracts.
enum LitheFeatureAvailability {
    /// Pull request support is temporarily hidden while the macOS credential
    /// and signing story is being redesigned for preview and contributor builds.
    static let githubPullRequests = false
}

struct WorkbenchNotification: Identifiable, Equatable {
    let id: UUID
    let message: String
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID = UUID(),
        message: String,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.message = message
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

struct DebugBreakpointPresentationState {
    var isManagerPresented = false
    var pendingEditor: GenericDebugBreakpoint?

    mutating func reset() {
        isManagerPresented = false
        pendingEditor = nil
    }
}

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

    var isAvailable: Bool {
        switch self {
        case .pullRequests:
            LitheFeatureAvailability.githubPullRequests
        case .project, .changes, .search, .database:
            true
        }
    }
}

typealias ProjectItemEditKind = LitheCoreContracts.ProjectItemEditKind
typealias ProjectItemEditRequest = LitheCoreContracts.ProjectItemEditRequest
typealias ProjectItemDeletionRequest = LitheCoreContracts.ProjectItemDeletionRequest

enum FindNotificationKeys {
    static let query = "query"
    static let direction = "direction"
    static let matchCase = "matchCase"
    static let wholeWords = "wholeWords"
    static let regularExpression = "regularExpression"
    static let replacement = "replacement"
    /// 替换通知的目标文档标识；接收编辑器必须与之匹配才执行替换。
    static let documentID = "documentID"
}

extension Notification.Name {
    static let litheFindQueryChanged = Notification.Name("litheFindQueryChanged")
    static let litheFindNavigate = Notification.Name("litheFindNavigate")
    static let litheFindDismiss = Notification.Name("litheFindDismiss")
    static let litheFindReplaceNext = Notification.Name("litheFindReplaceNext")
    static let litheFindReplaceAll = Notification.Name("litheFindReplaceAll")
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
