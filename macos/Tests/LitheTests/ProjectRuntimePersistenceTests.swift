import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project runtime canonical persistence", .serialized)
@MainActor
struct ProjectRuntimePersistenceTests {
    @Test(arguments: [false, true])
    func migratesSubprojectPathsIntoExistingCanonicalDefaultsWithoutReplacingSavedChoices(existingPaths: Bool) throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let key = MacProjectRuntimeSettingsStore.preferencesKey(root)
        var legacy = ProjectRuntimeSettings(javaHomePath: "/fixture/old-project-jdk")
        legacy.setOverride(path: "services/a", javaHomePath: "/fixture/a-jdk", mavenExecutablePath: "/fixture/a-mvn")
        legacy.setOverride(path: "services/b", mavenExecutablePath: "./mvnw", mavenJavaHomePath: "/fixture/b-maven-jdk")
        preferences.set(try JSONEncoder().encode(legacy), forKey: key)
        let local = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        var toolchain: [String: Any] = ["java": ["homePath": "/fixture/saved-project-jdk"]]
        if existingPaths { toolchain["pathOverrides"] = ["services/a": ["javaHomePath": "/fixture/saved-a-jdk"]] }
        try JSONSerialization.data(withJSONObject: ["version": 2, "toolchain": toolchain, "configurations": []]).write(to: local)
        let store = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        let migrated = try store.load(at: root, migrateLegacy: true)
        #expect(migrated.settings.javaHomePath == "/fixture/saved-project-jdk")
        #expect(migrated.settings.exactOverride(for: "services/a")?.javaHomePath == (existingPaths ? "/fixture/saved-a-jdk" : "/fixture/a-jdk"))
        #expect(migrated.settings.exactOverride(for: "services/b")?.mavenExecutablePath == (existingPaths ? nil : "./mvnw"))
        let preferenceData = try #require(preferences.data(forKey: key))
        let cleaned = try #require(JSONSerialization.jsonObject(with: preferenceData) as? [String: Any])
        #expect(cleaned["moduleOverrides"] == nil)
        let bytes = try Data(contentsOf: local)
        let reopened = try store.load(at: root, migrateLegacy: false)
        #expect(reopened.settings == migrated.settings)
        #expect(try Data(contentsOf: local) == bytes)
        var edited = reopened.settings
        edited.setOverride(path: "services/a", javaHomePath: "/fixture/edited-a-jdk")
        let saved = try store.save(edited, at: root, expecting: reopened)
        #expect(saved.settings.exactOverride(for: "services/a")?.javaHomePath == "/fixture/edited-a-jdk")
        #expect(try store.load(at: root, migrateLegacy: false).settings == saved.settings)
        #expect(saved.settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/a/module").javaHomePath == "/fixture/edited-a-jdk")
        #expect(saved.settings.overlay(onto: RunOptions(), workspaceRelativePath: "services/another").javaHomePath == "/fixture/saved-project-jdk")
    }

    @Test(arguments: ["outside", "duplicate", "unknown"])
    func invalidSubprojectPathRetainsLegacyDataAndDoesNotCreateCanonicalDocument(kind: String) throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let key = MacProjectRuntimeSettingsStore.preferencesKey(root)
        let path = kind == "outside" ? "../escape" : "services/a"
        var overrides: [[String: Any]] = [["path": path, "javaHomePath": "/fixture/jdk"]]
        if kind == "duplicate" { overrides.append(["path": path, "javaHomePath": "/fixture/another-jdk"]) }
        if kind == "unknown" { overrides[0]["futureField"] = "preserve-this-value" }
        let original = try JSONSerialization.data(withJSONObject: ["moduleOverrides": overrides])
        preferences.set(original, forKey: key)
        let store = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        #expect(throws: (any Error).self) { try store.load(at: root, migrateLegacy: true) }
        #expect(preferences.data(forKey: key) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/local.json").path))
    }

    @Test(arguments: [false, true])
    func migratesLegacyOnlyAfterReadingTheCanonicalSelection(existingCanonical: Bool) throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let store = MacProjectRuntimeSettingsStore(core: core, storage: MacFileStorage(), preferences: preferences)
        let key = MacProjectRuntimeSettingsStore.preferencesKey(root)
        let legacy = ProjectRuntimeSettings(javaHomePath: "/fixture/old-jdk", mavenHomeSelection: .wrapper,
            mavenJavaHomePath: "/fixture/old-maven-jdk")
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        document["futurePreference"] = true
        document["mavenSettingsPath"] = "/fixture/settings.xml"
        let original = try JSONSerialization.data(withJSONObject: document)
        preferences.set(original, forKey: key)
        let expected = existingCanonical ? ProjectToolchainSelection() : legacy.projectToolchainSelection()
        if existingCanonical {
            // Explicit automatic is a saved choice and wins over old overrides.
            try MacRunConfigurationStore(core: core, storage: MacFileStorage(), preferences: preferences)
                .saveProjectToolchain(expected, at: root)
        }
        let readOnly = try store.load(at: root, migrateLegacy: false)
        #expect(preferences.data(forKey: key) == original)
        #expect(readOnly.settings.projectToolchainSelection() == ProjectToolchainSelection())
        let migrated = try store.load(at: root, migrateLegacy: true)
        #expect(migrated.settings.projectToolchainSelection() == expected)
        let savedPreferences = try #require(preferences.data(forKey: key))
        let cleaned = try #require(JSONSerialization.jsonObject(with: savedPreferences) as? [String: Any])
        for field in ["javaHomePath", "mavenHomePath", "mavenHomeSelection", "mavenJavaHomePath"] {
            #expect(cleaned[field] == nil)
        }
        #expect(cleaned["futurePreference"] as? Bool == true)
        #expect(cleaned["mavenSettingsPath"] as? String == "/fixture/settings.xml")
        let local = root.appendingPathComponent(".lithe/run/local.json")
        let bytes = try Data(contentsOf: local)
        _ = try store.load(at: root, migrateLegacy: true)
        #expect(try Data(contentsOf: local) == bytes)
        #expect(preferences.data(forKey: key) == savedPreferences)
        let ignore = try String(contentsOf: root.appendingPathComponent(".lithe/.gitignore"), encoding: .utf8)
        #expect(ignore.contains("run/local.json"))
    }

    @Test
    func invalidCanonicalDocumentPreservesBothSourcesAndBlocksRuntimeSelection() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let key = MacProjectRuntimeSettingsStore.preferencesKey(root)
        let legacy = try JSONEncoder().encode(ProjectRuntimeSettings(javaHomePath: "/fixture/old-jdk"))
        preferences.set(legacy, forKey: key)
        let local = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("{broken".utf8)
        try invalid.write(to: local)
        let store = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        #expect(throws: (any Error).self) { try store.load(at: root, migrateLegacy: true) }
        let service = ProjectRuntimeService(runtimeLocator: ProjectRuntimeSettingsTestLocator(), settingsStore: store)
        service.openProject(at: root)
        #expect(service.javaHomeURL() == nil)
        #expect(service.mavenExecutable(at: root) == nil)
        #expect(service.settingsError != nil)
        #expect(preferences.data(forKey: key) == legacy)
        #expect(try Data(contentsOf: local) == invalid)
    }

    @Test(arguments: [false, true])
    func nonDataRuntimePreferenceCannotBecomeAutomaticOrBeRemovedByMigration(migrate: Bool) throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let key = MacProjectRuntimeSettingsStore.preferencesKey(root)
        preferences.set("retain the malformed preference", forKey: key)
        let store = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        #expect(throws: (any Error).self) { try store.load(at: root, migrateLegacy: migrate) }
        let service = ProjectRuntimeService(runtimeLocator: ProjectRuntimeSettingsTestLocator(), settingsStore: store)
        service.openProject(at: root)
        #expect(service.javaHomeURL() == nil)
        #expect(service.mavenExecutable(at: root) == nil)
        #expect(service.settingsError != nil)
        #expect(preferences.object(forKey: key) as? String == "retain the malformed preference")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/local.json").path))
    }

    @Test
    func draftCancelSaveReadBackAndExternalEditUseTheSameSource() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let store = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        let service = ProjectRuntimeService(runtimeLocator: ProjectRuntimeSettingsTestLocator(), settingsStore: store)
        let feature = RuntimeSettingsFeatureModel(service: service)
        service.openProject(at: root)
        prepare(feature, root: root)
        let local = root.appendingPathComponent(".lithe/run/local.json")
        #expect(!FileManager.default.fileExists(atPath: local.path))
        feature.updateSettings { $0.javaHomePath = "/fixture/draft-jdk" }
        #expect(!FileManager.default.fileExists(atPath: local.path))
        #expect(service.settings.javaHomePath.isEmpty)
        feature.cancelChanges()
        #expect(!feature.hasChanges)
        #expect(feature.saveSettings())
        feature.finishSaving()
        #expect(!FileManager.default.fileExists(atPath: local.path))
        feature.updateSettings { $0.javaHomePath = "/fixture/saved-jdk" }
        #expect(feature.saveSettings())
        #expect(feature.isSaving)
        feature.updateSettings { $0.javaHomePath = "/fixture/blocked-edit" }
        #expect(feature.settings.javaHomePath == "/fixture/saved-jdk")
        #expect(!feature.saveSettings())
        feature.finishSaving()
        #expect(service.javaHomeURL()?.path == "/fixture/saved-jdk")
        #expect(!feature.hasChanges)
        let baseline = try store.load(at: root, migrateLegacy: false)
        var external = baseline.settings
        external.javaHomePath = "/fixture/external-jdk"
        _ = try store.save(external, at: root, expecting: baseline)
        feature.updateSettings { $0.javaHomePath = "/fixture/kept-draft" }
        // A launch refreshes its source while a settings draft is open. It must
        // not replace that draft's baseline and make a stale save appear valid.
        #expect(service.javaHomeURL()?.path == "/fixture/external-jdk")
        #expect(!feature.saveSettings())
        #expect(feature.settings.javaHomePath == "/fixture/kept-draft")
        #expect(feature.settingsError != nil)
        #expect(try store.load(at: root, migrateLegacy: false).settings.javaHomePath == "/fixture/external-jdk")
        feature.cancelChanges()
        #expect(feature.settings.javaHomePath == "/fixture/external-jdk")
        #expect(!feature.hasChanges)
        let other = try workspace()
        defer { try? FileManager.default.removeItem(at: other) }
        let otherSnapshot = try store.load(at: other, migrateLegacy: false)
        #expect(throws: (any Error).self) { try store.save(otherSnapshot.settings, at: root, expecting: otherSnapshot) }
        service.closeProject()
        service.openProject(at: root)
        #expect(service.javaHomeURL()?.path == "/fixture/external-jdk")
    }

    @Test
    func failedMigrationRetainsLegacyPreferences() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = RuntimeMigrationPreferences()
        let key = MacProjectRuntimeSettingsStore.preferencesKey(root)
        let original = try JSONEncoder().encode(ProjectRuntimeSettings(javaHomePath: "/fixture/jdk"))
        preferences.set(original, forKey: key)
        var storage = MacFileStorage()
        storage.unsupportedExchangeForTesting = true
        let store = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: storage, preferences: preferences)
        #expect(throws: (any Error).self) { try store.load(at: root, migrateLegacy: true) }
        #expect(preferences.data(forKey: key) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/local.json").path))
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-canonical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func prepare(_ feature: RuntimeSettingsFeatureModel, root: URL) {
        feature.prepare(workspaceName: "fixture", workspaceURL: root, files: [])
    }
}

private final class RuntimeMigrationPreferences: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
