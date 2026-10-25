import Foundation
@testable import Lithe
import LitheModuleAPI
import Testing

/// What the former built-in database module saved, moved once into the
/// database plugin's state and credentials, in the format the plugin reads.
struct MacDatabasePluginMigrationTests {
    private static let pluginID = DatabasePluginTransition.pluginID.rawValue
    private static let production = "6F1B0B6E-6A8E-4C35-9F0B-1E2D3C4B5A60"
    private static let scratch = "0C2A7B1D-3E4F-4A5B-8C6D-7E8F9A0B1C2D"
    private static let reporting = "9A8B7C6D-5E4F-4321-8765-0FEDCBA98765"
    private static let analytics = "11111111-2222-4333-8444-555555555555"

    @Test
    func connectionsHistoryAndForeverPasswordsMoveIntoThePlugin() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.set(try json([
            ["id": Self.scratch, "name": "scratch", "kind": "sqlite", "path": "/tmp/scratch.db",
             "passwordPersistence": "untilRestart"],
            ["id": Self.production, "name": "Production", "kind": "postgresql", "host": "db.example",
             "port": 5432, "folderID": Self.analytics, "productionProtection": true],
            ["id": Self.reporting, "name": "Reporting", "kind": "mysql", "group": " Reports "],
        ]), forKey: MacDatabasePluginMigration.profilesKey)
        fixture.preferences.set(try json([["id": Self.analytics, "name": "Analytics"]]),
                                forKey: MacDatabasePluginMigration.foldersKey)
        // 2025-01-01T00:00:00Z is 757,382,400 s after 2001.
        fixture.preferences.set(try json([
            ["id": "A0000000-0000-4000-8000-000000000001", "profileID": Self.production, "sql": "SELECT 1",
             "kind": "query", "executedAt": 757_382_400.25, "durationMilliseconds": 3],
            ["id": "A0000000-0000-4000-8000-000000000002", "profileID": "DELETED0-0000-4000-8000-000000000000",
             "sql": "SELECT 2", "kind": "query", "executedAt": 757_382_400, "durationMilliseconds": 1],
        ]), forKey: MacDatabasePluginMigration.historyKey)
        fixture.legacyPasswords["database.connection.\(Self.production).password"] = "pg-secret"
        fixture.legacyPasswords["database.connection.\(Self.reporting).password"] = "my-secret"
        fixture.legacyPasswords["database.connection.\(Self.scratch).password"] = "never-kept"

        #expect(fixture.migration.prepare(installation: .fromLitheStore(), stateDirectory: fixture.state)
            == .migrated(profiles: 3, passwords: 2))

        #expect(try fixture.credentials.secret(pluginID: Self.pluginID, key: "connection:\(Self.production):password") == "pg-secret")
        #expect(try fixture.credentials.secret(pluginID: Self.pluginID, key: "connection:\(Self.reporting):password") == "my-secret")
        #expect(try fixture.credentials.secret(pluginID: Self.pluginID, key: "connection:\(Self.scratch):password") == nil)

        let connections = try fixture.object("connections.json")
        #expect(connections["schemaVersion"] as? Int == 1)
        let profiles = try #require(connections["profiles"] as? [[String: Any]])
        #expect(profiles.compactMap { $0["name"] as? String } == ["Production", "Reporting", "scratch"])
        #expect(profiles[0]["productionProtection"] as? Bool == true)
        #expect(profiles[0]["folderID"] as? String == Self.analytics)
        // A legacy group becomes a top-level folder, as the old module did.
        let folders = try #require(connections["folders"] as? [[String: Any]])
        let reports = try #require(folders.first { $0["name"] as? String == "Reports" })
        #expect(profiles[1]["folderID"] as? String == reports["id"] as? String)
        #expect(profiles[1]["group"] as? String == "")

        let history = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.state
            .appendingPathComponent("sql-history.json"))) as? [[String: Any]])
        #expect(history.count == 1)
        #expect(history[0]["executedAt"] as? Int == 1_735_689_600_250)

        let stored = try String(contentsOf: fixture.state.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!stored.contains("secret"))
        // The old data stays for an older Lithe.
        #expect(fixture.preferences.data(forKey: MacDatabasePluginMigration.profilesKey) != nil)
    }

    @Test
    func theMoveHappensOnceAndNeverReplacesThePluginsOwnConnections() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.set(try json([["id": Self.production, "name": "Production", "kind": "postgresql"]]),
                                forKey: MacDatabasePluginMigration.profilesKey)

        #expect(fixture.migration.prepare(installation: .fromLitheStore(id: "dev.example.other"), stateDirectory: fixture.state) == .otherPlugin)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))

        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
        let own = Data(#"{"schemaVersion":1,"profiles":[],"folders":[]}"#.utf8)
        try own.write(to: fixture.state.appendingPathComponent("connections.json"))
        #expect(fixture.migration.prepare(installation: .fromLitheStore(), stateDirectory: fixture.state) == .keptPluginState)
        #expect(try Data(contentsOf: fixture.state.appendingPathComponent("connections.json")) == own)

        try FileManager.default.removeItem(at: fixture.state)
        #expect(fixture.migration.prepare(installation: .fromLitheStore(), stateDirectory: fixture.state) == .alreadyMigrated)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    }

    /// The package is unsigned, so its ID proves nothing: only the copy
    /// Lithe Store lists from the plugin's repository receives the data.
    @Test(arguments: [
        PluginInstallationRecord.fromDisk(),
        .fromLitheStore(sourceID: "example-source"),
        .fromLitheStore(repository: "https://github.com/example/lithe-plugin-database"),
    ])
    func aCopyFromAnywhereElseReceivesNothing(installation: PluginInstallationRecord) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.set(try json([["id": Self.production, "name": "Production", "kind": "postgresql"]]),
                                forKey: MacDatabasePluginMigration.profilesKey)
        fixture.legacyPasswords["database.connection.\(Self.production).password"] = "pg-secret"

        #expect(fixture.migration.prepare(installation: installation, stateDirectory: fixture.state) == .untrustedSource)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
        #expect(try fixture.credentials.secret(pluginID: Self.pluginID, key: "connection:\(Self.production):password") == nil)
        // The copy from Lithe Store still receives everything later.
        #expect(fixture.preferences.object(forKey: MacDatabasePluginMigration.markerKey) == nil)
        #expect(fixture.migration.prepare(installation: .fromLitheStore(), stateDirectory: fixture.state)
            == .migrated(profiles: 1, passwords: 1))
    }

    @Test
    func aPasswordThatCannotMoveLeavesItsConnectionAskingAgain() throws {
        let fixture = try Fixture(credentials: LockedCredentials())
        defer { fixture.remove() }
        fixture.preferences.set(try json([["id": Self.production, "name": "Production", "kind": "postgresql"]]),
                                forKey: MacDatabasePluginMigration.profilesKey)
        fixture.legacyPasswords["database.connection.\(Self.production).password"] = "pg-secret"

        #expect(fixture.migration.prepare(installation: .fromLitheStore(), stateDirectory: fixture.state)
            == .migrated(profiles: 1, passwords: 0))
        #expect(fixture.logged.messages.count == 1)
        #expect(fixture.logged.messages.allSatisfy { !$0.contains("pg-secret") })
    }

    @Test
    func withoutSavedConnectionsOnlyTheMarkerIsWritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(fixture.migration.prepare(installation: .fromLitheStore(), stateDirectory: fixture.state) == .nothingToMigrate)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
        #expect(fixture.preferences.object(forKey: MacDatabasePluginMigration.markerKey) != nil)
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
}

private struct Fixture {
    let root: URL
    let state: URL
    let preferences = MigrationPreferences()
    let credentials: any PluginCredentialStoring
    let logged = MigrationLog()
    let legacyPasswordBox = LegacyPasswords()
    let migration: MacDatabasePluginMigration

    var legacyPasswords: [String: String] {
        get { legacyPasswordBox.values }
        nonmutating set { legacyPasswordBox.values = newValue }
    }

    init(credentials: any PluginCredentialStoring = MemoryPluginCredentialStore()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-database-migration-\(UUID().uuidString)", isDirectory: true)
        state = root.appendingPathComponent("state/io.github.lithe-idea.database/backend", isDirectory: true)
        self.credentials = credentials
        let passwords = legacyPasswordBox
        let log = logged
        migration = MacDatabasePluginMigration(
            preferences: preferences,
            legacyPassword: { key in passwords.values[key] },
            credentials: credentials,
            log: { message in log.append(message) }
        )
    }

    func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent(name))) as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MigrationPreferences: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class LegacyPasswords: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    var values: [String: String] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class MigrationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var messages: [String] { lock.withLock { recorded } }
    func append(_ message: String) { lock.withLock { recorded.append(message) } }
}

private struct LockedCredentials: PluginCredentialStoring {
    struct Locked: LocalizedError { var errorDescription: String? { "The Keychain is locked." } }
    func secret(pluginID _: String, key _: String) throws -> String? { throw Locked() }
    func setSecret(_: String, pluginID _: String, key _: String) throws { throw Locked() }
    func deleteSecret(pluginID _: String, key _: String) throws { throw Locked() }
    func deleteAll(pluginID _: String) throws { throw Locked() }
}

private extension PluginInstallationRecord {
    static func fromLitheStore(
        id: String = DatabasePluginTransition.pluginID.rawValue,
        sourceID: String = PluginMarketplaceSource.communityID,
        repository: String = DatabasePluginTransition.repository
    ) -> PluginInstallationRecord {
        PluginInstallationRecord(
            pluginID: PluginID(id),
            activeVersion: PluginVersion(major: 0, minor: 1, patch: 0),
            origin: .community,
            marketplace: PluginMarketplaceProvenance(
                sourceID: sourceID, sourceName: "Lithe Store", repository: repository,
                archiveSHA256: String(repeating: "0", count: 64), contentDigest: "digest", approvedPrograms: []
            )
        )
    }

    static func fromDisk() -> PluginInstallationRecord {
        PluginInstallationRecord(
            pluginID: DatabasePluginTransition.pluginID,
            activeVersion: PluginVersion(major: 0, minor: 1, patch: 0),
            origin: .community,
            disk: PluginDiskProvenance(fileName: "database.zip", archiveSHA256: nil, contentDigest: "digest", approvedPrograms: [])
        )
    }
}
