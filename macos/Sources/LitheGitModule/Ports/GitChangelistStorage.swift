import Foundation

/// Persistence stays with the platform. Missing data is distinct from unreadable data.
@MainActor
package protocol GitChangelistStorage {
    func load(workspace: URL) throws -> GitLocalChangelists?
    func save(_ state: GitLocalChangelists, workspace: URL) throws
}
