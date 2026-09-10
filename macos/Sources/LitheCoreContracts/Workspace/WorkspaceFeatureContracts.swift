import Foundation

package struct WorkspaceDocumentState: Sendable {
    package let url: URL
    package let isDirty: Bool

    package init(url: URL, isDirty: Bool) {
        self.url = url
        self.isDirty = isDirty
    }
}

package struct WorkspaceSession: Codable, Sendable {
    package let openPaths: [String]
    package let activePath: String?
    package let selectedSidebar: String

    package init(openPaths: [String], activePath: String?, selectedSidebar: String) {
        self.openPaths = openPaths
        self.activePath = activePath
        self.selectedSidebar = selectedSidebar
    }
}

@MainActor
package protocol WorkspaceSessionStoring: AnyObject {
    func load(for workspaceURL: URL) -> WorkspaceSession?
    func save(_ session: WorkspaceSession, for workspaceURL: URL)
}

package protocol WorkspaceOperations: Sendable {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot?
    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules)
    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: FileVisibilityRules)
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules)
    func readFile(at rootURL: URL, relativePath: String) -> String?
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool
}

/// User-selected semantic role for a directory in the project tree.
/// Values use workspace-relative paths and are stored in host application preferences.
package enum WorkspaceDirectoryMark: String, CaseIterable, Codable, Sendable {
    case plain
    case sources
    case resources
    case excluded
    case module
    case package
}

/// Persists directory roles without changing the marked directories themselves.
package protocol WorkspaceDirectoryMarkStoring: Sendable {
    func loadDirectoryMarks(for workspaceURL: URL) throws -> [String: WorkspaceDirectoryMark]
    func saveDirectoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        for workspaceURL: URL
    ) throws
}

package struct EmptyWorkspaceDirectoryMarkStore: WorkspaceDirectoryMarkStoring {
    package init() {}

    package func loadDirectoryMarks(
        for workspaceURL: URL
    ) throws -> [String: WorkspaceDirectoryMark] {
        [:]
    }

    package func saveDirectoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        for workspaceURL: URL
    ) throws {}
}

package extension WorkspaceOperations {
    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {}
    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: FileVisibilityRules) {}
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {}
}

package protocol DirectoryWatcherFactory {
    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource
}

package protocol GitWatchContextProviding: Sendable {
    func watchContext(for workspace: URL) async -> GitWatchContext?
}

package enum ProjectItemEditKind: Sendable {
    case createFile
    case createDirectory
    case rename
}

package struct ProjectItemEditRequest: Identifiable, Sendable {
    package let id: UUID
    package let kind: ProjectItemEditKind
    package let targetURL: URL

    package init(id: UUID = UUID(), kind: ProjectItemEditKind, targetURL: URL) {
        self.id = id
        self.kind = kind
        self.targetURL = targetURL
    }
}

package struct ProjectItemDeletionRequest: Identifiable, Sendable {
    package let id: UUID
    package let url: URL
    package let isDirectory: Bool

    package init(id: UUID = UUID(), url: URL, isDirectory: Bool) {
        self.id = id
        self.url = url
        self.isDirectory = isDirectory
    }
}

package struct GitWatchContext: Equatable, Sendable {
    package let repositoryRoot: URL
    package let gitDirectory: URL
    package let gitCommonDirectory: URL

    package init(repositoryRoot: URL, gitDirectory: URL, gitCommonDirectory: URL) {
        self.repositoryRoot = repositoryRoot
        self.gitDirectory = gitDirectory
        self.gitCommonDirectory = gitCommonDirectory
    }
}

public enum LocalHistoryReason: String, Codable, Sendable {
    case projectBaseline
    case saved
    case externalChange
    case beforeRename
    case beforeDelete
    case beforeBatchReplace
    case unsavedDiscard
    case restored

    public var title: String {
        switch self {
        case .projectBaseline: "Project opened"
        case .saved: "File saved"
        case .externalChange: "External change"
        case .beforeRename: "Before rename"
        case .beforeDelete: "Before deletion"
        case .beforeBatchReplace: "Before project replacement"
        case .unsavedDiscard: "Discarded editor changes"
        case .restored: "Before restore"
        }
    }
}
