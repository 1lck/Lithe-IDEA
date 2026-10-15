import Foundation
import LitheCoreContracts

// Note: 声明式插件设置的归属与取值规则见 .agents/notes/implemented/feature/2026-10-14-declarative-plugin-settings.md

/// Keeps the user's values for declarative plugin settings in the app's
/// preferences, one record per plugin. The record holds only what the user
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

    private static func key(_ pluginID: String) -> String {
        "lithe.plugins.\(pluginID).settings"
    }
}
