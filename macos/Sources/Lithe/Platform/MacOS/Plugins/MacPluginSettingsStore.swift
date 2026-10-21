import Foundation
import LitheCoreContracts

// Note: 声明式插件设置的归属与取值规则见 .agents/notes/implemented/feature/2026-10-14-declarative-plugin-settings.md

/// Keeps the user's values for declarative plugin settings: global values in
/// the app's preferences, one record per plugin; project values in the
/// project's `.lithe/plugin-settings.json`, keyed by plugin, so a team shares
/// them through version control. Each record holds only what the user
/// changed; Rust Core supplies the declared default for everything else.
final class MacPluginSettingsStore: PluginSettingsStoring, @unchecked Sendable {
    private let store: any KeyValueStore
    private let lock = NSLock()

    init(store: any KeyValueStore) {
        self.store = store
    }

    func values(forPlugin pluginID: String) -> [String: ToolingJSONValue] {
        lock.lock(); defer { lock.unlock() }
        return recordLocked(pluginID)
    }

    func setValue(_ value: ToolingJSONValue?, forSetting settingID: String, plugin pluginID: String) {
        lock.lock(); defer { lock.unlock() }
        var record = recordLocked(pluginID)
        record[settingID] = value
        // An empty record is removed so an untouched plugin leaves nothing behind.
        let data = record.isEmpty ? nil : try? JSONEncoder().encode(record)
        store.set(data, forKey: Self.key(pluginID))
    }

    /// A record that cannot be read is treated as empty, so a damaged
    /// preference never blocks the language server from starting with its
    /// defaults; the next change replaces it.
    private func recordLocked(_ pluginID: String) -> [String: ToolingJSONValue] {
        guard let data = store.data(forKey: Self.key(pluginID)),
              let record = try? JSONDecoder().decode([String: ToolingJSONValue].self, from: data)
        else { return [:] }
        return record
    }

    func projectValues(forPlugin pluginID: String, projectRoot: URL) -> [String: ToolingJSONValue] {
        lock.lock(); defer { lock.unlock() }
        return Self.projectDocument(at: projectRoot)[pluginID] ?? [:]
    }

    func setProjectValue(
        _ value: ToolingJSONValue?,
        forSetting settingID: String,
        plugin pluginID: String,
        projectRoot: URL
    ) throws {
        lock.lock(); defer { lock.unlock() }
        var document = Self.projectDocument(at: projectRoot)
        var record = document[pluginID] ?? [:]
        record[settingID] = value
        document[pluginID] = record.isEmpty ? nil : record
        let url = try Self.projectFile(at: projectRoot)
        if document.isEmpty {
            // Nothing overridden: leave no file behind for the team to review.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    /// The project file, refusing a `.lithe` that resolves outside the
    /// project so a symlink cannot redirect the write.
    private static func projectFile(at projectRoot: URL) throws -> URL {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(".lithe", isDirectory: true)
        let resolved = directory.resolvingSymlinksInPath()
        guard resolved.path == directory.path || !FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory.appendingPathComponent("plugin-settings.json")
    }

    /// A damaged project file reads as empty, as with the global record.
    private static func projectDocument(at projectRoot: URL) -> [String: [String: ToolingJSONValue]] {
        guard let url = try? projectFile(at: projectRoot),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode([String: [String: ToolingJSONValue]].self, from: data)
        else { return [:] }
        return document
    }

    private static func key(_ pluginID: String) -> String {
        "lithe.plugins.\(pluginID).settings"
    }
}
