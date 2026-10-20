import Foundation
import LitheCoreContracts
import LitheDebugModule

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case editor = "Editor"
    case keymap = "Keymap"
    case project = "Project"
    case run = "Run configurations"
    case terminal = "Terminal"
    case lsp = "LSP"
    case ai = "AI & Commit"
    case agents = "Agents"
    case providers = "AI Providers"
    case git = "Git"
    case updates = "Updates"
    case processTermination = "Process Termination Policy"
    case diagnostics = "Diagnostics"
    case plugins = "Plugins"
    case mcp = "MCP Configuration"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: "Project · JDK & Maven"
        case .diagnostics: "Logs and Diagnostics"
        default: rawValue
        }
    }

    /// The sidebar group that owns this page, or `nil` for a top-level page.
    var group: SettingsGroup? {
        SettingsGroup.allCases.first { $0.categories.contains(self) }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .editor: "textformat"
        case .keymap: "keyboard"
        case .project: "shippingbox"
        case .run: "play.rectangle"
        case .terminal: "terminal"
        case .lsp: "server.rack"
        case .ai: "wand.and.stars"
        case .agents: "sparkles"
        case .providers: "key"
        case .git: "arrow.triangle.branch"
        case .updates: "arrow.down.circle"
        case .processTermination: "power"
        case .diagnostics: "stethoscope"
        case .plugins: "puzzlepiece.extension"
        case .mcp: "network"
        }
    }
}

/// Collapsible groups of the settings sidebar. A new page is declared here, in
/// the group whose subject it configures, rather than added as a loose entry.
/// The ownership rules are in
/// `.agents/notes/implemented/feature/2026-10-15-macos-settings-hierarchy.md`.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case appearance = "Appearance & Behavior"
    case versionControl = "Version Control"
    case build = "Build, Execution, Deployment"
    case languages = "Languages & Frameworks"
    case tools = "Tools"
    case ai = "AI"

    var id: String { rawValue }

    /// Pages in display order.
    var categories: [SettingsCategory] {
        switch self {
        case .appearance: [.general, .updates, .editor, .keymap, .processTermination]
        case .versionControl: [.git]
        case .build: [.project, .run]
        case .languages: [.lsp]
        case .tools: [.terminal, .diagnostics]
        case .ai: [.mcp, .ai, .agents, .providers]
        }
    }
}

/// One top-level row of the settings sidebar.
enum SettingsSidebarItem {
    case group(SettingsGroup)
    case page(SettingsCategory)

    /// Top-level order: plugins sit between Appearance & Behavior and the
    /// feature groups because they extend every group below them.
    static let layout: [SettingsSidebarItem] = [
        .group(.appearance),
        .page(.plugins),
        .group(.versionControl),
        .group(.build),
        .group(.languages),
        .group(.tools),
        .group(.ai),
    ]
}

enum JavaLaunchDecisionResolution: Equatable {
    case runOnce
    case alwaysContinue
    case rebuildIndex
    case cancel
}

struct PendingJavaLaunchDecision: Identifiable, Equatable {
    let id: UUID
    let workspaceURL: URL
    let failure: JavaLaunchBuildFailure
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
    /// Raw substitutions stay locale-independent until balloon/history rendering.
    let arguments: [String]
    let createdAt: Date
    /// When the message was shown last. Repeating a message keeps the single
    /// entry but moves this forward, so the list reports fresh activity.
    var updatedAt: Date
    var isRead: Bool
    /// How often the same message has been shown. The first appearance is 1;
    /// later appearances raise the count instead of adding a duplicate row.
    var occurrenceCount = 1
    /// Transient overflow attached to this balloon; history retains each message.
    var collapsedCount = 0

    init(
        id: UUID = UUID(),
        message: String,
        arguments: [String] = [],
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.message = message
        self.arguments = arguments
        self.createdAt = createdAt
        self.updatedAt = createdAt
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

/// Legacy workspace sessions keep their original names; new tool windows use
/// their stable contribution ID without extending a closed destination enum.
struct SidebarDestination: RawRepresentable, Hashable, Identifiable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    init(contributionID: String) {
        switch contributionID {
        case "workspace.project": self = .project
        case "git.changes": self = .changes
        case "github.pull-requests": self = .pullRequests
        case "search.workspace": self = .search
        default: rawValue = contributionID
        }
    }
    static let project = Self(rawValue: "project")!
    static let changes = Self(rawValue: "changes")!
    static let pullRequests = Self(rawValue: "pullRequests")!
    static let search = Self(rawValue: "search")!

    var contributionID: String {
        switch self {
        case .project: "workspace.project"
        case .changes: "git.changes"
        case .pullRequests: "github.pull-requests"
        case .search: "search.workspace"
        default: rawValue
        }
    }
    var id: String { rawValue }
    var isAvailable: Bool {
        self != .pullRequests || LitheFeatureAvailability.githubPullRequests
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
    /// URL of the tree row that displays `url`, following the path rather than
    /// visiting every node.
    static func matchingURL(for url: URL, in node: FileNode) -> URL? {
        node.displayedNode(for: url)?.url
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
