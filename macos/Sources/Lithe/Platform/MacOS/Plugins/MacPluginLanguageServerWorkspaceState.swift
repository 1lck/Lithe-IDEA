import Foundation
import LitheCoreContracts

// Note: 插件自有语言服务器会话与后端决定启动方式见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

/// The per-workspace state of a plugin-owned language server (plan API-20).
/// The server writes into the `${workspaceStateDir}` the host created for the
/// workspace; this type keeps those directories bounded and lets the user
/// discard one.
///
/// Rust Core decides which directories to delete from the plugin's declared
/// retention; this type only lists what is on disk, hands Core the facts, and
/// removes the names Core returns. It touches nothing outside the host's own
/// plugin state area: never the app bundle, a plugin package, or a project.
struct MacPluginLanguageServerWorkspaceState: Sendable {
    private let directories: MacPluginStateDirectories
    private let planner: any DeclarativeLanguageServerLaunchPlanning
    private let now: @Sendable () -> Date

    init(
        directories: MacPluginStateDirectories,
        planner: any DeclarativeLanguageServerLaunchPlanning,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directories = directories
        self.planner = planner
        self.now = now
    }

    /// Records that the server starts for this workspace now. A directory's
    /// own modification time is the only "last used" the host can see, and
    /// the server writes deeper than that, so each start refreshes it.
    func markUsed(_ source: DeclarativeLanguageServerLaunchSource, workspaceRootURL: URL) throws {
        let directory = workspaceDirectory(of: source, workspaceRootURL: workspaceRootURL)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: directory.path)
    }

    /// Deletes the workspaces' state the plugin's retention says to drop and
    /// returns their names. A workspace in `openWorkspaceURLs` is never
    /// deleted; a plugin that declares no retention keeps everything.
    @discardableResult
    func prune(
        _ source: DeclarativeLanguageServerLaunchSource,
        openWorkspaceURLs: [URL]
    ) throws -> [String] {
        guard let retention = source.stateRetention else { return [] }
        let parent = directories.workspaceStatesDirectory(pluginID: source.pluginID, languageID: source.languageID)
        let entries = try observedEntries(in: parent)
        guard !entries.isEmpty else { return [] }
        let expired = try planner.expiredLanguageServerStateNames(
            retention: retention,
            nowUnixSeconds: max(0, Int(now().timeIntervalSince1970)),
            entries: entries,
            activeNames: openWorkspaceURLs.map(MacPluginStateDirectories.workspaceDigest)
        )
        // Only a directory this call listed is deleted, whatever Core names.
        let listed = Set(entries.map(\.name))
        let removable = expired.filter(listed.contains)
        for name in removable {
            try FileManager.default.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
        }
        return removable
    }

    /// Discards the state of one workspace. The server rebuilds it the next
    /// time it starts; the host recreates the directory then.
    func reset(_ source: DeclarativeLanguageServerLaunchSource, workspaceRootURL: URL) throws {
        let directory = workspaceDirectory(of: source, workspaceRootURL: workspaceRootURL)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func workspaceDirectory(of source: DeclarativeLanguageServerLaunchSource, workspaceRootURL: URL) -> URL {
        directories.workspaceStateDirectory(
            pluginID: source.pluginID, languageID: source.languageID, workspaceRootURL: workspaceRootURL
        )
    }

    /// The real directories under `parent` and when each was last used. A
    /// file or a link is not state the host created, so it is not listed.
    private func observedEntries(in parent: URL) throws -> [LanguageServerStateEntry] {
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys), options: [])
        return try children.compactMap { child -> LanguageServerStateEntry? in
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate else { return nil }
            return LanguageServerStateEntry(
                name: child.lastPathComponent, lastModifiedUnixSeconds: max(0, Int(modified.timeIntervalSince1970))
            )
        }
    }
}
