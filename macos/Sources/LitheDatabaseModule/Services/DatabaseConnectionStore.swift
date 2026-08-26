import Foundation

package struct DatabaseProfile: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package var name: String
    package var kind: DatabaseKind
    package var host: String
    package var port: UInt16
    package var username: String
    package var database: String
    package var path: String
    package var ssl: Bool
    /// Legacy display grouping. New profiles use folderID; retain this field so
    /// older saved profiles can be migrated without losing the user's grouping.
    package var group: String
    package var folderID: UUID?
    package var colorHex: String
    package var readOnly: Bool
    package var productionProtection: Bool
    package var maskSensitiveFields: Bool
    package var sensitiveColumnPatterns: [String]
    package var caCertificatePath: String
    package var serverName: String
    package var sshHost: String
    package var sshPort: UInt16
    package var sshUsername: String
    package var sshKeyPath: String
    package var sshLocalPort: UInt16
    package var proxyURL: String

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, username, database, path, ssl, group, folderID, colorHex
        case readOnly, productionProtection, maskSensitiveFields, sensitiveColumnPatterns
        case caCertificatePath, serverName, sshHost, sshPort, sshUsername, sshKeyPath, sshLocalPort, proxyURL
    }

    package init(id: UUID = UUID(), name: String, kind: DatabaseKind, host: String = "127.0.0.1", port: UInt16 = 0, username: String = "", database: String = "", path: String = "", ssl: Bool = false, group: String = "", folderID: UUID? = nil, colorHex: String = "", readOnly: Bool = false, productionProtection: Bool = false, maskSensitiveFields: Bool = false, sensitiveColumnPatterns: [String] = ["password", "secret", "token", "api_key"], caCertificatePath: String = "", serverName: String = "", sshHost: String = "", sshPort: UInt16 = 0, sshUsername: String = "", sshKeyPath: String = "", sshLocalPort: UInt16 = 0, proxyURL: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port
        self.username = username; self.database = database; self.path = path; self.ssl = ssl
        self.group = group; self.folderID = folderID; self.colorHex = colorHex; self.readOnly = readOnly; self.productionProtection = productionProtection; self.maskSensitiveFields = maskSensitiveFields; self.sensitiveColumnPatterns = sensitiveColumnPatterns
        self.caCertificatePath = caCertificatePath; self.serverName = serverName; self.sshHost = sshHost; self.sshPort = sshPort; self.sshUsername = sshUsername; self.sshKeyPath = sshKeyPath; self.sshLocalPort = sshLocalPort; self.proxyURL = proxyURL
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(DatabaseKind.self, forKey: .kind)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 0
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        ssl = try container.decodeIfPresent(Bool.self, forKey: .ssl) ?? false
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        productionProtection = try container.decodeIfPresent(Bool.self, forKey: .productionProtection) ?? false
        maskSensitiveFields = try container.decodeIfPresent(Bool.self, forKey: .maskSensitiveFields) ?? false
        sensitiveColumnPatterns = try container.decodeIfPresent([String].self, forKey: .sensitiveColumnPatterns) ?? ["password", "secret", "token", "api_key"]
        caCertificatePath = try container.decodeIfPresent(String.self, forKey: .caCertificatePath) ?? ""
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = try container.decodeIfPresent(UInt16.self, forKey: .sshPort) ?? 0
        sshUsername = try container.decodeIfPresent(String.self, forKey: .sshUsername) ?? ""
        sshKeyPath = try container.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? ""
        sshLocalPort = try container.decodeIfPresent(UInt16.self, forKey: .sshLocalPort) ?? 0
        proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
    }
}

package struct DatabaseConnectionFolder: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package var name: String
    package var parentID: UUID?

    package init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

package final class DatabaseConnectionStore: @unchecked Sendable {
    private static let profilesKey = "database.profiles.v1"
    private static let foldersKey = "database.connection-folders.v1"
    private static let sqlHistoryKey = "database.sql-history.v1"
    private static let backupSchedulesKey = "database.backup-schedules.v1"
    private static let maximumHistoryEntries = 100
    private let store: any DatabasePreferenceStore
    private let secureStore: any DatabaseSecureStore

    package init(store: any DatabasePreferenceStore, secureStore: any DatabaseSecureStore) {
        self.store = store
        self.secureStore = secureStore
    }

    package func load() -> [DatabaseProfile] {
        guard let data = store.data(forKey: Self.profilesKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseProfile].self, from: data)) ?? []
    }

    package func save(_ profiles: [DatabaseProfile]) throws {
        store.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
    }

    package func loadFolders() -> [DatabaseConnectionFolder] {
        guard let data = store.data(forKey: Self.foldersKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseConnectionFolder].self, from: data)) ?? []
    }

    package func saveFolders(_ folders: [DatabaseConnectionFolder]) throws {
        store.set(try JSONEncoder().encode(folders), forKey: Self.foldersKey)
    }

    package func loadSQLHistory() -> [DatabaseSQLHistoryEntry] {
        guard let data = store.data(forKey: Self.sqlHistoryKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseSQLHistoryEntry].self, from: data)) ?? []
    }

    package func appendSQLHistory(_ entry: DatabaseSQLHistoryEntry) throws {
        var entries = loadSQLHistory().filter { $0.id != entry.id }
        entries.insert(entry, at: 0)
        store.set(try JSONEncoder().encode(Array(entries.prefix(Self.maximumHistoryEntries))), forKey: Self.sqlHistoryKey)
    }

    package func deleteSQLHistory(for profileID: UUID) throws {
        let remaining = loadSQLHistory().filter { $0.profileID != profileID }
        store.set(try JSONEncoder().encode(remaining), forKey: Self.sqlHistoryKey)
    }

    package func loadBackupSchedules() -> [DatabaseBackupSchedule] {
        guard let data = store.data(forKey: Self.backupSchedulesKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseBackupSchedule].self, from: data)) ?? []
    }

    package func saveBackupSchedules(_ schedules: [DatabaseBackupSchedule]) throws {
        store.set(try JSONEncoder().encode(schedules), forKey: Self.backupSchedulesKey)
    }

    package func deleteBackupSchedule(for profileID: UUID) throws {
        try saveBackupSchedules(loadBackupSchedules().filter { $0.profileID != profileID })
    }

    package func password(for id: UUID) -> String { secureStore.read(key: passwordKey(id)) ?? "" }
    package func hasPassword(for id: UUID) -> Bool { secureStore.read(key: passwordKey(id)) != nil }
    package func savePassword(_ password: String, for id: UUID) throws { try secureStore.write(password, key: passwordKey(id)) }
    package func deletePassword(for id: UUID) throws { try secureStore.delete(key: passwordKey(id)) }
    private func passwordKey(_ id: UUID) -> String { "database.connection.\(id.uuidString).password" }
}
