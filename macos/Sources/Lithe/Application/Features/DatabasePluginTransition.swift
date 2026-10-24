import Foundation
import LitheModuleAPI

// Note: 数据库改为插件后的老用户提示与迁移见 .agents/notes/implemented/architecture/2026-10-24-database-provider-plugin.md

/// Lithe no longer contains a database module; the official Database plugin
/// replaces it. Someone who saved connections in the old module learns that
/// once, and their data moves into the plugin when it first runs
/// (`MacDatabasePluginMigration`). Nothing downloads on its own.
enum DatabasePluginTransition {
    /// Where the old module saved its connection profiles.
    static let legacyProfilesKey = "database.profiles.v1"
    static let suggestionKey = "lithe.databasePluginSuggestion.v1"

    /// Suggest the plugin when the old module saved connections, the plugin
    /// is not installed, and the suggestion was never shown.
    static func shouldSuggest(store: any KeyValueStore, installedPluginIDs: Set<PluginID>) -> Bool {
        guard store.object(forKey: suggestionKey) == nil,
              !installedPluginIDs.contains(OfficialPluginCatalog.databasePluginID),
              let data = store.data(forKey: legacyProfilesKey),
              let profiles = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return false }
        return !profiles.isEmpty
    }
}
