import Foundation

/// A settings draft is tied to both the local run document and the remaining
/// Lithe preferences. The revision is opaque and must not contain file contents.
struct ProjectRuntimeSettingsSnapshot: Equatable {
    let workspaceURL: URL
    let settings: ProjectRuntimeSettings
    let revision: String
    var hasSavedToolchain = false
}

@MainActor
protocol ProjectRuntimeSettingsStoring {
    /// Migration is allowed only during workspace activation, never page display.
    func load(at workspace: URL, migrateLegacy: Bool) throws -> ProjectRuntimeSettingsSnapshot
    func save(_ settings: ProjectRuntimeSettings, at workspace: URL,
              expecting snapshot: ProjectRuntimeSettingsSnapshot) throws -> ProjectRuntimeSettingsSnapshot
}
