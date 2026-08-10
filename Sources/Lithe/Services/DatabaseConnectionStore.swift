import Foundation

struct DatabaseProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var kind: DatabaseKind
    var host: String
    var port: UInt16
    var username: String
    var database: String
    var path: String
    var ssl: Bool
    /// Legacy display grouping. New profiles use folderID; retain this field so
    /// older saved profiles can be migrated without losing the user's grouping.
    var group: String
    var folderID: UUID?
    var colorHex: String
    var readOnly: Bool
    var productionProtection: Bool
    var maskSensitiveFields: Bool
    var sensitiveColumnPatterns: [String]
    var caCertificatePath: String
    var serverName: String
    var sshHost: String
    var sshPort: UInt16
    var sshUsername: String
    var sshKeyPath: String
    var sshLocalPort: UInt16
    var proxyURL: String

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, username, database, path, ssl, group, folderID, colorHex
        case readOnly, productionProtection, maskSensitiveFields, sensitiveColumnPatterns
        case caCertificatePath, serverName, sshHost, sshPort, sshUsername, sshKeyPath, sshLocalPort, proxyURL
    }

    init(id: UUID = UUID(), name: String, kind: DatabaseKind, host: String = "127.0.0.1", port: UInt16 = 0, username: String = "", database: String = "", path: String = "", ssl: Bool = false, group: String = "", folderID: UUID? = nil, colorHex: String = "", readOnly: Bool = false, productionProtection: Bool = false, maskSensitiveFields: Bool = false, sensitiveColumnPatterns: [String] = ["password", "secret", "token", "api_key"], caCertificatePath: String = "", serverName: String = "", sshHost: String = "", sshPort: UInt16 = 0, sshUsername: String = "", sshKeyPath: String = "", sshLocalPort: UInt16 = 0, proxyURL: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port
        self.username = username; self.database = database; self.path = path; self.ssl = ssl
        self.group = group; self.folderID = folderID; self.colorHex = colorHex; self.readOnly = readOnly; self.productionProtection = productionProtection; self.maskSensitiveFields = maskSensitiveFields; self.sensitiveColumnPatterns = sensitiveColumnPatterns
        self.caCertificatePath = caCertificatePath; self.serverName = serverName; self.sshHost = sshHost; self.sshPort = sshPort; self.sshUsername = sshUsername; self.sshKeyPath = sshKeyPath; self.sshLocalPort = sshLocalPort; self.proxyURL = proxyURL
    }

    init(from decoder: Decoder) throws {
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

struct DatabaseConnectionFolder: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

final class DatabaseConnectionStore: @unchecked Sendable {
    private static let profilesKey = "database.profiles.v1"
    private static let foldersKey = "database.connection-folders.v1"
    private static let sqlHistoryKey = "database.sql-history.v1"
    private static let backupSchedulesKey = "database.backup-schedules.v1"
    private static let maximumHistoryEntries = 100
    private let store: any KeyValueStore
    private let secureStore: any SecureStore

    init(store: any KeyValueStore, secureStore: any SecureStore) {
        self.store = store
        self.secureStore = secureStore
    }

    func load() -> [DatabaseProfile] {
        guard let data = store.data(forKey: Self.profilesKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [DatabaseProfile]) throws {
        store.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
    }

    func loadFolders() -> [DatabaseConnectionFolder] {
        guard let data = store.data(forKey: Self.foldersKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseConnectionFolder].self, from: data)) ?? []
    }

    func saveFolders(_ folders: [DatabaseConnectionFolder]) throws {
        store.set(try JSONEncoder().encode(folders), forKey: Self.foldersKey)
    }

    func loadSQLHistory() -> [DatabaseSQLHistoryEntry] {
        guard let data = store.data(forKey: Self.sqlHistoryKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseSQLHistoryEntry].self, from: data)) ?? []
    }

    func appendSQLHistory(_ entry: DatabaseSQLHistoryEntry) throws {
        var entries = loadSQLHistory().filter { $0.id != entry.id }
        entries.insert(entry, at: 0)
        store.set(try JSONEncoder().encode(Array(entries.prefix(Self.maximumHistoryEntries))), forKey: Self.sqlHistoryKey)
    }

    func deleteSQLHistory(for profileID: UUID) throws {
        let remaining = loadSQLHistory().filter { $0.profileID != profileID }
        store.set(try JSONEncoder().encode(remaining), forKey: Self.sqlHistoryKey)
    }

    func loadBackupSchedules() -> [DatabaseBackupSchedule] {
        guard let data = store.data(forKey: Self.backupSchedulesKey) else { return [] }
        return (try? JSONDecoder().decode([DatabaseBackupSchedule].self, from: data)) ?? []
    }

    func saveBackupSchedules(_ schedules: [DatabaseBackupSchedule]) throws {
        store.set(try JSONEncoder().encode(schedules), forKey: Self.backupSchedulesKey)
    }

    func deleteBackupSchedule(for profileID: UUID) throws {
        try saveBackupSchedules(loadBackupSchedules().filter { $0.profileID != profileID })
    }

    func password(for id: UUID) -> String { secureStore.read(key: passwordKey(id)) ?? "" }
    func hasPassword(for id: UUID) -> Bool { secureStore.read(key: passwordKey(id)) != nil }
    func savePassword(_ password: String, for id: UUID) throws { try secureStore.write(password, key: passwordKey(id)) }
    func deletePassword(for id: UUID) throws { try secureStore.delete(key: passwordKey(id)) }
    private func passwordKey(_ id: UUID) -> String { "database.connection.\(id.uuidString).password" }
}
