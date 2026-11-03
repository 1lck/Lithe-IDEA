import Foundation

/// Wire data for the pure shared ChangeList reducer. Persistence remains host-owned.
package struct GitChangelistCoreRequest: Encodable, Sendable {
    package struct State: Codable, Sendable {
        package let lists: [GitLocalChangelist]
        package let activeId: String
        package let assignments: [String: [String: String]]

        package init(_ state: GitLocalChangelists) {
            lists = state.lists
            activeId = state.activeID
            assignments = state.assignments
        }

        package var local: GitLocalChangelists {
            var value = GitLocalChangelists()
            value.lists = lists
            value.activeID = activeId
            value.assignments = assignments
            return value
        }
    }
    package struct File: Encodable, Sendable {
        package let root: String
        package let path: String
        package let originalPath: String?
        package let isCopy: Bool

        package init(_ change: GitChange) {
            root = change.repositoryRoot.standardizedFileURL.path
            path = change.path
            originalPath = change.originalPath
            isCopy = change.indexStatus == "C" || change.workTreeStatus == "C"
        }
    }
    package struct Action: Encodable, Sendable {
        package let type: String
        package var id: String?
        package var name: String?
        package var files: [File]?
        package init(type: String, id: String? = nil, name: String? = nil, files: [File]? = nil) {
            self.type = type
            self.id = id
            self.name = name
            self.files = files
        }
    }
    package let state: State
    package let files: [File]
    package let repositories: [GitWorkspaceRepositoryBinding]
    package let action: Action?

    package init(state: GitLocalChangelists, changes: [GitChange], repositories: [GitWorkspaceRepositoryBinding] = [], action: Action? = nil) {
        self.state = State(state)
        files = changes.map(File.init)
        self.repositories = repositories
        self.action = action
    }
}

package struct GitChangelistCoreProjection: Decodable, Sendable {
    package let state: GitChangelistCoreRequest.State
    package let members: [String]
    package let scope: GitWorkspaceCommitPathScope
}
