import Foundation
import Testing
@testable import Lithe

struct MacDevelopmentProfileMigrationTests {
    @Test
    func firstLaunchCopiesSettingsAndWorkspaceThenKeepsBothProfilesIndependent() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let session = Data("workspace-tabs".utf8)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        fixture.defaults.setPersistentDomain([
            "settings.theme": "dark", "lithe.recent-projects": "recent",
            "lithe.workspace-session./fixture/project": session,
            "appUpdateChannel": "stable", "settings.customLogDirectory": "/fixture/shared-logs",
            "SUSkippedVersion": "9", "lithe.plugins.pending-code-load": "stale-plugin"
        ], forName: fixture.sourceDomain)
        try fixture.write("Lithe/ai-secrets.json", text: "independent-secret-file")
        try fixture.write("Lithe/Maven/config.json", text: "maven-settings")
        try fixture.write("Lithe/PluginMarketplace/sources.json", text: "marketplace")
        try fixture.write("Lithe/PluginMarketplace/downloads/runtime.lock", text: "must-not-import")

        #expect(try fixture.prepare() == .imported)
        #expect(fixture.defaults.string(forKey: "settings.theme") == "dark")
        #expect(fixture.defaults.data(forKey: "lithe.workspace-session./fixture/project") == session)
        #expect(fixture.defaults.object(forKey: "appUpdateChannel") == nil)
        #expect(fixture.defaults.object(forKey: "settings.customLogDirectory") == nil)
        #expect(fixture.defaults.object(forKey: "SUSkippedVersion") == nil)
        #expect(fixture.defaults.object(forKey: "lithe.plugins.pending-code-load") == nil)
        #expect(fixture.defaults.string(forKey: MacDevelopmentProfileMigration.markerKey) == "imported")
        #expect(AppUpdateChannel.saved(in: fixture.defaults, defaultChannel: .autobuild) == .autobuild)
        let target = fixture.destination.appendingPathComponent("Lithe/ai-secrets.json")
        #expect(try String(contentsOf: target, encoding: .utf8) == "independent-secret-file")
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("Lithe/PluginMarketplace/downloads").path))

        fixture.defaults.set("dev-theme", forKey: "settings.theme")
        try Data("dev-secret".utf8).write(to: target)
        #expect(try fixture.prepare() == .existing)
        #expect(fixture.defaults.string(forKey: "settings.theme") == "dev-theme")
        #expect(fixture.defaults.persistentDomain(forName: fixture.sourceDomain)?["settings.theme"] as? String == "dark")
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("Lithe/ai-secrets.json"), encoding: .utf8) == "independent-secret-file")
    }

    @Test
    func firstLaunchCopiesDatabasePreferencesAndCustomBackgroundAccess() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let preferences: [String: Data] = [
            "database.profiles.v1": Data("connection-profiles".utf8),
            "database.connection-folders.v1": Data("connection-folders".utf8),
            "database.sql-history.v1": Data("sql-history".utf8),
            "database.backup-schedules.v1": Data("backup-schedules".utf8),
            "settings.workbenchBackground": Data("custom-background-selection".utf8),
            "platform.macos.workbenchBackgroundImageAccess": Data("opaque-image-access".utf8)
        ]
        fixture.defaults.setPersistentDomain(preferences, forName: fixture.sourceDomain)

        #expect(try fixture.prepare() == .imported)
        for (key, value) in preferences {
            #expect(fixture.defaults.data(forKey: key) == value)
        }
        #expect(fixture.defaults.string(forKey: MacDevelopmentProfileMigration.markerKey) == "imported")

        // The copied records remain independent and are not refreshed from Stable.
        fixture.defaults.set(Data("dev-profile".utf8), forKey: "database.profiles.v1")
        #expect(try fixture.prepare() == .existing)
        #expect(fixture.defaults.data(forKey: "database.profiles.v1") == Data("dev-profile".utf8))
        #expect(fixture.defaults.persistentDomain(forName: fixture.sourceDomain)?["database.profiles.v1"] as? Data == preferences["database.profiles.v1"])
    }

    @Test(arguments: [
        "database.profiles.v1", "database.connection-folders.v1",
        "database.sql-history.v1", "database.backup-schedules.v1",
        "platform.macos.workbenchBackgroundImageAccess"
    ], [false, true])
    func existingAdapterPreferenceAlonePreventsImport(key: String, emptyDirectoryExists: Bool) throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let existing = Data("existing-dev-configuration".utf8)
        fixture.defaults.setPersistentDomain(["settings.theme": "stable"], forName: fixture.sourceDomain)
        fixture.defaults.set(existing, forKey: key)
        if emptyDirectoryExists {
            try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        }

        #expect(try fixture.prepare() == .existing)
        #expect(fixture.defaults.data(forKey: key) == existing)
        #expect(fixture.defaults.object(forKey: "settings.theme") == nil)
        #expect(fixture.defaults.object(forKey: MacDevelopmentProfileMigration.markerKey) == nil)
    }

    @Test
    func existingDevelopmentPreferencesOrFilesAreNeverMerged() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        fixture.defaults.setPersistentDomain(["settings.theme": "stable"], forName: fixture.sourceDomain)
        fixture.defaults.set("existing-dev", forKey: "settings.theme")
        #expect(try fixture.prepare() == .existing)
        #expect(fixture.defaults.string(forKey: "settings.theme") == "existing-dev")
        fixture.defaults.removePersistentDomain(forName: fixture.destinationDomain)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        try Data("existing-workspace".utf8).write(to: fixture.destination.appendingPathComponent("workspace.json"))
        #expect(try fixture.prepare() == .existing)
        #expect(fixture.defaults.object(forKey: "settings.theme") == nil)
        #expect(try String(contentsOf: fixture.destination.appendingPathComponent("workspace.json"), encoding: .utf8) == "existing-workspace")
    }

    @Test
    func interruptedPreferenceCommitResumesFromThePublishedSnapshot() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let snapshot = try PropertyListSerialization.data(fromPropertyList: ["settings.theme": "snapshot"], format: .binary, options: 0)
        try snapshot.write(to: fixture.destination.appendingPathComponent(".stable-profile-import-v1.plist"))
        fixture.defaults.setPersistentDomain(["settings.theme": "changed-since-copy"], forName: fixture.sourceDomain)
        #expect(try fixture.prepare() == .imported)
        #expect(fixture.defaults.string(forKey: "settings.theme") == "snapshot")
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(".stable-profile-import-v1.plist").path))
    }

    @Test
    func failedCopyIsRetryableAndFreshProfilesDoNotImportLaterStableChanges() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        try fixture.write("Lithe/original.json", text: "stable-data")
        let secret = fixture.root.appendingPathComponent("Lithe/ai-secrets.json")
        try FileManager.default.createSymbolicLink(at: secret, withDestinationURL: fixture.root.appendingPathComponent("Lithe/original.json"))
        #expect(throws: (any Error).self) { try fixture.prepare() }
        #expect(fixture.defaults.object(forKey: MacDevelopmentProfileMigration.markerKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try FileManager.default.removeItem(at: secret)
        #expect(try fixture.prepare() == .fresh)
        fixture.defaults.setPersistentDomain(["settings.theme": "later-stable"], forName: fixture.sourceDomain)
        #expect(try fixture.prepare() == .existing)
        #expect(fixture.defaults.object(forKey: "settings.theme") == nil)
    }
}

private struct ProfileFixture {
    let root: URL
    let sourceDomain: String
    let destinationDomain: String
    let defaults: UserDefaults
    var destination: URL { root.appendingPathComponent("app.lithe.desktop.dev") }

    init() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-profile-import-" + id)
        sourceDomain = "lithe.test.stable." + id
        destinationDomain = "lithe.test.dev." + id
        defaults = UserDefaults(suiteName: destinationDomain)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func prepare() throws -> MacDevelopmentProfileMigration.Outcome {
        try MacDevelopmentProfileMigration.prepare(
            identity: MacAppIdentity(bundleIdentifier: "app.lithe.desktop.dev"), defaults: defaults,
            supportDirectory: root, sourceDomain: sourceDomain, destinationDomain: destinationDomain
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: sourceDomain)
        defaults.removePersistentDomain(forName: destinationDomain)
        try? FileManager.default.removeItem(at: root)
    }
}
