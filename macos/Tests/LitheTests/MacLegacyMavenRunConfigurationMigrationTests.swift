import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Legacy Maven Run migration")
@MainActor
struct MacLegacyMavenRunConfigurationMigrationTests {
    @Test
    func generationMigratesBothLayersWithStableIDsAndNoDuplicateService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = MigrationPreferences()
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        let manifest = try Data(contentsOf: fixture.root.appendingPathComponent(".lithe/project.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.team.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.local.path)
        _ = try store.generate(at: fixture.root, files: [], modulePaths: [], javaEntrypoints: nil,
            projectOwnership: fixture.projects, providerRuns: fixture.runs, models: fixture.models, lease: RunConfigurationGenerationLease())
        let resolution = try store.resolve(at: fixture.root, toolchainCandidates: [])
        let service = try #require(resolution.configurations.first)
        #expect(resolution.configurations.count == 1)
        #expect(service.configuration.id == fixture.id)
        #expect(service.configuration.buildProvider == fixture.runs[0].reference)
        #expect(resolution.defaultConfigurationID == fixture.id)
        #expect(!resolution.diagnostics.contains { $0.code == "orphanedOverride" })
        let inputs = try store.providerLaunchInputs(at: fixture.root, configurationID: fixture.id, providerRoot: "nested")
        #expect(inputs.launchOptions.runtimeArguments == ["--runtime=one two", "", "雪"])
        #expect(inputs.launchOptions.entrypoint == "opaque/entry:1")
        #expect(inputs.launchOptions.arguments == ["--local=雪"])
        #expect(inputs.launchOptions.environment == ["EXAMPLE": "local"])
        #expect(inputs.launchOptions.workingDirectory == "nested/app/work")
        #expect(inputs.optionOverrides == ["skipTests": .bool(false)])
        let team = try fixture.read(fixture.team), local = try fixture.read(fixture.local)
        #expect((team["annotation"] as? String) == "keep document metadata")
        #expect(((team["configurations"] as? [[String: Any]])?.first?["extensions"] as? [String: Any])?["maven"] == nil)
        #expect((((team["configurations"] as? [[String: Any]])?.first?["extensions"] as? [String: Any])?["annotations"] as? [String: Bool]) == ["keep": true])
        #expect((local["annotation"] as? String) == "keep local metadata")
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".lithe/project.json")) == manifest)
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.team.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.local.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let bytes = try fixture.bytes()
        _ = try store.generate(at: fixture.root, files: [], modulePaths: [], javaEntrypoints: nil,
            projectOwnership: fixture.projects, providerRuns: fixture.runs, models: fixture.models, lease: RunConfigurationGenerationLease())
        #expect(try fixture.bytes() == bytes, "A successful cutover is idempotent without another receipt file")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".lithe/run/generated.json").path))
    }

    @Test(arguments: ["tools", "version", "ambiguous", "preferences", "saved-preferences", "invalid-entrypoint", "changed-framework", "invalid-maven", "invalid-selector", "custom-debug"])
    func unsupportedSourcesAndFailedPreflightLeaveBothDocumentsUntouched(reason: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = MigrationPreferences()
        var team = try fixture.read(fixture.team)
        var entries = try #require(team["configurations"] as? [[String: Any]])
        var entry = entries[0], extensions = try #require(entry["extensions"] as? [String: Any])
        if reason == "tools" { extensions["java"] = ["homePath": "/fixture/custom-jdk"]; entry["extensions"] = extensions }
        if reason == "invalid-maven" { extensions["maven"] = "invalid legacy value"; entry["extensions"] = extensions }
        if reason == "invalid-selector" {
            var maven = try #require(extensions["maven"] as? [String: Any]); maven["module"] = 42
            extensions["maven"] = maven; entry["extensions"] = extensions
        }
        if reason == "custom-debug" { entry["debug"] = ["adapter": "dev.example.custom"] }
        if reason == "saved-preferences" {
            entry["id"] = "user:legacy-service"
            var local = try fixture.read(fixture.local), localItems = try #require(fixture.read(fixture.local)["configurations"] as? [[String: Any]])
            localItems[0]["id"] = "user:legacy-service"; local["configurations"] = localItems
            try fixture.write(local, to: fixture.local)
        }
        if reason == "version" { team["version"] = 1 }
        if reason == "invalid-entrypoint" {
            var maven = try #require(extensions["maven"] as? [String: Any]); maven["mainClass"] = String(repeating: "a", count: 4097)
            extensions["maven"] = maven; entry["extensions"] = extensions
        }
        entries[0] = entry; team["configurations"] = entries
        try fixture.write(team, to: fixture.team)
        var runs = fixture.runs
        if reason == "ambiguous" {
            let other = BuildProviderRunReference(pluginID: "io.github.lithe-idea.maven-build", buildSystemID: "maven", root: "nested",
                run: "framework", projectID: "p", targetID: "other/opaque", execution: .service)
            runs.append(RunProviderConfiguration(projectPath: "nested/app", name: "Other", reference: other))
        }
        if reason == "preferences" || reason == "saved-preferences" {
            let key = fixture.root.path.replacingOccurrences(of: "/", with: "_")
            let id = reason == "saved-preferences" ? "user:legacy-service" : fixture.id
            preferences.set(Data("retired choices".utf8), forKey: "lithe.java-run-options.\(key).\(id)")
        }
        let before = try fixture.bytes()
        let models: [BuildModel]
        if reason == "changed-framework" {
            models = [try JSONDecoder().decode(BuildModel.self, from: Data(#"{"projects":[{"id":"p","path":"nested/app","name":"app"}],"targets":[{"id":"opaque/service","projectID":"p","name":"micronaut.maven","path":"nested/app","tags":["maven-service"]}]}"#.utf8))]
        } else { models = try fixture.models }
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        #expect(throws: (any Error).self) {
            _ = try store.generate(at: fixture.root, files: [], modulePaths: [], javaEntrypoints: nil,
                projectOwnership: fixture.projects, providerRuns: runs, models: models, lease: RunConfigurationGenerationLease())
        }
        #expect(try fixture.bytes() == before)
    }

    @Test(arguments: ["before", "after-first-write", "after-second-write", "second-file-conflict", "changed-source", "changed-first-during-rollback", "changed-local-after-write", "preferences-created-during-write", "marker-changed-during-write"])
    func cancellationAndConflictsUseConditionalRollbackWithoutOverwritingNewerBytes(mode: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lease = RunConfigurationGenerationLease(), storage = MigrationFaultStorage(), preferences = MigrationPreferences()
        let migration = MacLegacyMavenRunConfigurationMigration(storage: storage, preferences: preferences, immutableRoots: [])
        let plan = try migration.prepare(workspace: fixture.root, projects: fixture.projects, runs: fixture.runs, models: fixture.models, lease: lease)
        #expect(plan.writes.count == 2)
        let original = try fixture.bytes()
        let external = Data(#"{"version":2,"configurations":[],"external":"preserve"}"#.utf8)
        if mode == "before" { lease.invalidate() }
        if mode == "changed-source" { try external.write(to: fixture.local) }
        storage.beforeReplace = { index in
            if index == 2 && mode == "second-file-conflict" { try external.write(to: fixture.local) }
            if index == 2 && mode == "changed-first-during-rollback" {
                try external.write(to: fixture.team); try external.write(to: fixture.local)
            }
        }
        storage.afterReplace = { index in
            if (index == 1 && mode == "after-first-write") || (index == 2 && mode == "after-second-write") { lease.invalidate() }
            if index == 2 && mode == "changed-local-after-write" { try external.write(to: fixture.local) }
            let projectKey = fixture.root.path.replacingOccurrences(of: "/", with: "_")
            if index == 1 && mode == "preferences-created-during-write" {
                preferences.set(Data("new legacy choices".utf8), forKey: "lithe.java-run-options.\(projectKey).\(fixture.id)")
            }
            if index == 1 && mode == "marker-changed-during-write" {
                preferences.set(true, forKey: "lithe.run-configuration-migrated.\(projectKey)")
            }
        }
        #expect(throws: (any Error).self) { try migration.apply(plan, workspace: fixture.root, lease: lease) }
        if mode == "changed-first-during-rollback" {
            #expect(try Data(contentsOf: fixture.team) == external)
        } else { #expect(try Data(contentsOf: fixture.team) == original[0]) }
        let expectedLocal = ["second-file-conflict", "changed-source", "changed-first-during-rollback", "changed-local-after-write"].contains(mode) ? external : original[1]
        #expect(try Data(contentsOf: fixture.local) == expectedLocal)
    }

    @Test
    func changingAnUnwrittenSourceRollsBackOnlyOurDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalTeam = try fixture.read(fixture.team)
        try fixture.write(originalTeam, to: fixture.local)
        try fixture.write(["version": 2, "configurations": []], to: fixture.team)
        let beforeLocal = try Data(contentsOf: fixture.local)
        let storage = MigrationFaultStorage(), lease = RunConfigurationGenerationLease()
        let migration = MacLegacyMavenRunConfigurationMigration(storage: storage, preferences: MigrationPreferences(), immutableRoots: [])
        let plan = try migration.prepare(workspace: fixture.root, projects: fixture.projects, runs: fixture.runs, models: fixture.models, lease: lease)
        #expect(plan.writes.count == 1)
        let external = Data(#"{"version":2,"configurations":[],"external":"preserve"}"#.utf8)
        storage.afterReplace = { index in if index == 1 { try external.write(to: fixture.team) } }
        #expect(throws: (any Error).self) { try migration.apply(plan, workspace: fixture.root, lease: lease) }
        #expect(try Data(contentsOf: fixture.team) == external)
        #expect(try Data(contentsOf: fixture.local) == beforeLocal)
    }

    @Test
    func aReadOnlyWorkspaceWithoutLegacyEntriesRemainsReadable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(["version": 2, "configurations": []], to: fixture.team)
        try fixture.write(["version": 2, "configurations": []], to: fixture.local)
        let before = try fixture.bytes()
        let migration = MacLegacyMavenRunConfigurationMigration(storage: MacFileStorage(), preferences: MigrationPreferences(), immutableRoots: [fixture.root])
        let plan = try migration.prepare(workspace: fixture.root, projects: fixture.projects, runs: fixture.runs, models: fixture.models, lease: RunConfigurationGenerationLease())
        #expect(plan.writes.isEmpty)
        #expect(try fixture.bytes() == before)
    }

    @Test
    func immutablePackagesAndEscapingSymlinksRejectBeforePublication() throws {
        let fixture = try Fixture(), outside = try Fixture()
        defer { fixture.remove(); outside.remove() }
        let lease = RunConfigurationGenerationLease()
        let migration = MacLegacyMavenRunConfigurationMigration(storage: MacFileStorage(), preferences: MigrationPreferences(), immutableRoots: [fixture.root])
        let before = try fixture.bytes()
        #expect(throws: (any Error).self) { try migration.prepare(workspace: fixture.root, projects: fixture.projects, runs: fixture.runs, models: fixture.models, lease: lease) }
        #expect(try fixture.bytes() == before)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".lithe/run"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".lithe/run"), withDestinationURL: outside.root.appendingPathComponent(".lithe/run"))
        let external = try outside.bytes()
        let linked = MacLegacyMavenRunConfigurationMigration(storage: MacFileStorage(), preferences: MigrationPreferences(), immutableRoots: [])
        #expect(throws: (any Error).self) { try linked.prepare(workspace: fixture.root, projects: fixture.projects, runs: fixture.runs, models: fixture.models, lease: lease) }
        #expect(try outside.bytes() == external)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-maven-run-\(UUID().uuidString)")
        let id = "quarkus.maven:nested/app"
        var team: URL { root.appendingPathComponent(".lithe/run/configurations.json") }
        var local: URL { root.appendingPathComponent(".lithe/run/local.json") }
        let projects = [RunProjectOwnership(path: "nested/app", mavenReactorPath: "nested", contentRoots: [], name: "app")]
        var runs: [RunProviderConfiguration] {
            [.init(projectPath: "nested/app", name: "Current service", reference: .init(pluginID: "io.github.lithe-idea.maven-build",
                buildSystemID: "maven", root: "nested", run: "framework", projectID: "p", targetID: "opaque/service", execution: .service))]
        }
        var models: [BuildModel] {
            get throws {
                [try JSONDecoder().decode(BuildModel.self, from: Data(#"{"projects":[{"id":"p","path":"nested/app","name":"app"}],"targets":[{"id":"opaque/service","projectID":"p","name":"quarkus.maven","path":"nested/app","tags":["maven-service"]}]}"#.utf8))]
            }
        }
        init() throws {
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/app/work"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: team.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(["version": 2, "annotation": "keep document metadata", "configurations": [["id": id, "name": "User service", "provider": "quarkus.maven", "execution": "service", "cwd": "nested", "toolchains": ["java": "project-jdk", "maven": "project-maven"], "debug": ["adapter": "jdwp"], "extensions": ["maven": ["module": "app", "jvmArguments": ["--runtime=one two", "", "雪"], "programArguments": ["--team=space value"], "mainClass": "opaque/entry:1", "profiles": ["team"], "skipTests": true], "annotations": ["keep": true]]]]], to: team)
                try write(["version": 2, "annotation": "keep local metadata", "configurations": [["id": id, "cwd": "nested/app/work", "env": ["EXAMPLE": "local"], "extensions": ["maven": ["programArguments": ["--local=雪"], "profiles": [], "skipTests": false]]]]], to: local)
                try write(["version": 1, "defaultRunConfiguration": id], to: root.appendingPathComponent(".lithe/project.json"))
            } catch { remove(); throw error }
        }
        func read(_ url: URL) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
        func write(_ document: [String: Any], to url: URL) throws { try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url) }
        func bytes() throws -> [Data] { try [Data(contentsOf: team), Data(contentsOf: local)] }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// Faults occur at explicit synchronous publication boundaries, without timing or background tasks.
private final class MigrationFaultStorage: FileStorage, @unchecked Sendable {
    private let base = MacFileStorage()
    private var replacements = 0
    var beforeReplace: (Int) throws -> Void = { _ in }
    var afterReplace: (Int) throws -> Void = { _ in }
    func replaceDataPreservingMetadata(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        replacements += 1; let index = replacements
        try beforeReplace(index)
        let result = try base.replaceDataPreservingMetadata(data, at: url, expecting: expected)
        try afterReplace(index)
        return result
    }
    func homeDirectory() -> URL { base.homeDirectory() }
    func cacheDirectory() -> URL { base.cacheDirectory() }
    func applicationSupportDirectory() -> URL { base.applicationSupportDirectory() }
    func temporaryDirectory() -> URL { base.temporaryDirectory() }
    func metadata(for url: URL) -> FileMetadata? { base.metadata(for: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isExecutable(at url: URL) -> Bool { base.isExecutable(at: url) }
    func listDirectory(at url: URL) -> [URL] { base.listDirectory(at: url) }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data { try base.readPrefix(from: url, byteCount: byteCount) }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { try base.readData(from: url, options: options) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try base.writeData(data, to: url, options: options) }
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool { try base.replaceData(data, at: url, expecting: expected) }
    func removeData(at url: URL, expecting expected: Data) throws -> Bool { try base.removeData(at: url, expecting: expected) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try base.moveItem(at: sourceURL, to: destinationURL) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { try base.copyItem(at: sourceURL, to: destinationURL) }
}

private final class MigrationPreferences: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
