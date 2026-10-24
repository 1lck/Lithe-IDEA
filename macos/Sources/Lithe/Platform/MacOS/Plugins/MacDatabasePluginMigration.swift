import Foundation

// Note: 数据库改为插件后的老用户迁移见 .agents/notes/proposed/architecture/2026-10-24-database-provider-plugin.md

/// Moves what Lithe's former built-in database module saved into the
/// database plugin, once, before the plugin's backend first starts: the
/// connections, folders, and SQL history from the preferences into the
/// plugin's `${stateDir}`, and the passwords kept forever from the module's
/// Keychain service into the plugin's credentials.
///
/// The old data stays where it is, so an older Lithe still finds it, and a
/// marker records that the move happened. This is a transition shim that
/// knows both the old module's storage and the plugin's; remove it once no
/// supported Lithe version shipped the built-in module.
final class MacDatabasePluginMigration: @unchecked Sendable {
    static let pluginID = "dev.lithe.plugin.database"
    static let markerKey = "lithe.databasePluginMigration.v1"
    static let profilesKey = DatabasePluginTransition.legacyProfilesKey
    static let foldersKey = "database.connection-folders.v1"
    static let historyKey = "database.sql-history.v1"

    enum Outcome: Equatable {
        case otherPlugin
        case alreadyMigrated
        case nothingToMigrate
        /// The plugin already keeps connections of its own; they win.
        case keptPluginState
        case migrated(profiles: Int, passwords: Int)
        /// Nothing was marked, so the next start tries again.
        case failed(String)
    }

    /// Seconds between 1970 and 2001, the reference date the old module's
    /// `JSONEncoder` wrote history dates from.
    private static let referenceDateOffset: Double = 978_307_200
    private static let maximumHistoryEntries = 100

    // UserDefaults, behind `preferences`, is safe to use from any thread.
    private let preferences: any KeyValueStore
    private let legacyPassword: @Sendable (_ key: String) -> String?
    private let credentials: any PluginCredentialStoring
    private let fileManager: FileManager
    private let log: @Sendable (String) -> Void

    /// - Parameter legacyPassword: reads a password the old module stored,
    ///   by its old key, without writing anything.
    init(
        preferences: any KeyValueStore,
        legacyPassword: @escaping @Sendable (_ key: String) -> String?,
        credentials: any PluginCredentialStoring,
        fileManager: FileManager = .default,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.legacyPassword = legacyPassword
        self.credentials = credentials
        self.fileManager = fileManager
        self.log = log
    }

    @discardableResult
    func prepare(pluginID: String, stateDirectory: URL) -> Outcome {
        guard pluginID == Self.pluginID else { return .otherPlugin }
        guard preferences.object(forKey: Self.markerKey) == nil else { return .alreadyMigrated }
        let connectionsURL = stateDirectory.appendingPathComponent("connections.json")
        if fileManager.fileExists(atPath: connectionsURL.path) {
            markDone()
            return .keptPluginState
        }
        var profiles = objects(forKey: Self.profilesKey)
        var folders = objects(forKey: Self.foldersKey)
        guard !profiles.isEmpty || !folders.isEmpty else {
            markDone()
            return .nothingToMigrate
        }
        assignLegacyGroups(profiles: &profiles, folders: &folders)
        profiles.sort {
            (($0["name"] as? String) ?? "").localizedCaseInsensitiveCompare(($1["name"] as? String) ?? "") == .orderedAscending
        }

        // Passwords move first, so a migrated connection never points at a
        // password that is missing. A password that cannot move is logged,
        // and its connection asks for it again.
        var passwords = 0
        for profile in profiles where profile["passwordPersistence"] as? String != "untilRestart" {
            guard let id = profile["id"] as? String,
                  let password = legacyPassword("database.connection.\(id).password"),
                  !password.isEmpty else { continue }
            do {
                try credentials.setSecret(password, pluginID: pluginID, key: "connection:\(id):password")
                passwords += 1
            } catch {
                log("Database plugin migration could not move the password of connection \(id): \(error.localizedDescription)")
            }
        }

        let profileIDs = Set(profiles.compactMap { $0["id"] as? String })
        let history = objects(forKey: Self.historyKey)
            .filter { ($0["profileID"] as? String).map(profileIDs.contains) ?? false }
            .prefix(Self.maximumHistoryEntries)
            .map(Self.pluginHistoryEntry)
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            if !history.isEmpty {
                try write(history, to: stateDirectory.appendingPathComponent("sql-history.json"))
            }
            // Written last: its presence is what tells a later start that
            // the plugin has state of its own.
            try write(["schemaVersion": 1, "profiles": profiles, "folders": folders], to: connectionsURL)
        } catch {
            log("Database plugin migration could not write the plugin's state: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        markDone()
        return .migrated(profiles: profiles.count, passwords: passwords)
    }

    private func markDone() {
        preferences.set(Date().timeIntervalSince1970, forKey: Self.markerKey)
    }

    private func objects(forKey key: String) -> [[String: Any]] {
        guard let data = preferences.data(forKey: key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    /// Profiles saved before folders existed name their group; the old
    /// module made each name a top-level folder when it loaded them.
    private func assignLegacyGroups(profiles: inout [[String: Any]], folders: inout [[String: Any]]) {
        var folderIDs: [String: String] = [:]
        for folder in folders where Self.isAbsent(folder["parentID"]) {
            if let name = folder["name"] as? String, let id = folder["id"] as? String {
                folderIDs[name.lowercased()] = folderIDs[name.lowercased()] ?? id
            }
        }
        for index in profiles.indices where Self.isAbsent(profiles[index]["folderID"]) {
            let name = ((profiles[index]["group"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let id = folderIDs[name.lowercased()] ?? {
                let id = UUID().uuidString
                folders.append(["id": id, "name": name])
                folderIDs[name.lowercased()] = id
                return id
            }()
            profiles[index]["folderID"] = id
            profiles[index]["group"] = ""
        }
    }

    /// The old module omitted absent optionals; `null` counts the same.
    private static func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// The plugin keeps `executedAt` in milliseconds since 1970.
    private static func pluginHistoryEntry(_ entry: [String: Any]) -> [String: Any] {
        var entry = entry
        if let seconds = entry["executedAt"] as? Double {
            entry["executedAt"] = Int(((seconds + referenceDateOffset) * 1000).rounded())
        }
        return entry
    }

    private func write(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
