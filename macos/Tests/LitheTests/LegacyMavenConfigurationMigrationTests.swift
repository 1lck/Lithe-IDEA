import CryptoKit
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Legacy Maven configuration transfer", .serialized)
@MainActor
struct LegacyMavenConfigurationMigrationTests {
    @Test
    func transfersTeamChoicesAndReactorLocalPathsWithoutReplacingCanonicalValues() throws {
        let context = try Context()
        defer { context.clean() }
        let portable = MavenPortableConfiguration(selectedProfiles: [], customProfiles: ["not-selected", "ci"], skipTests: true)
        try context.legacy.saveMavenConfiguration(.init(portable: portable, local: .init(settingsPath: "/fixture/a.xml", localRepositoryPath: "/fixture/a-repository", mavenExecutablePath: "./mvnw", javaHomePath: "/fixture/a-jdk")), workspaceURL: context.workspace, reactorPath: "a")
        try context.legacy.saveMavenConfiguration(.init(portable: portable, local: .init(settingsPath: "/fixture/b.xml", javaHomePath: "/fixture/b-jdk")), workspaceURL: context.workspace, reactorPath: "b")
        try context.legacy.saveMavenConfiguration(.init(portable: portable, local: .init(settingsPath: "/fixture/absent.xml")), workspaceURL: context.workspace, reactorPath: "temporarily-absent")
        var shared = BuildProjectOptionsDocument()
        var maven = BuildProjectOptionsDocument.System()
        maven.instanceDefaults["skipTests"] = .bool(false)
        maven.savedChoices["profiles"] = ["new-custom"]
        shared.systems["maven"] = maven
        try context.options.saveProjectDocument(shared, workspace: context.workspace, expecting: nil)
        try context.options.setInstanceOptions(["b": ["settingsFile": .string("")]], workspaceURL: context.workspace, buildSystemID: "maven")
        let canonical = ProjectToolchainSelection(javaHomePath: "/fixture/project-jdk", pathOverrides: ["b": .init()])
        try context.run.saveProjectToolchain(canonical, at: context.workspace)
        #expect(try context.migration().migrate(workspace: context.workspace, reactorRoots: ["b", "a"]))
        let migrated = try context.options.projectDocument(context.workspace).document.systems["maven"]
        #expect(migrated?.instanceDefaults == ["profiles": .array([]), "skipTests": .bool(false)])
        #expect(migrated?.savedChoices["profiles"] == ["ci", "new-custom", "not-selected"])
        let local = try context.options.instanceOptions(workspaceURL: context.workspace, buildSystemID: "maven")
        #expect(local["a"] == ["settingsFile": .string("/fixture/a.xml"), "localRepository": .string("/fixture/a-repository")])
        #expect(local["b"] == ["settingsFile": .string("")])
        let toolchain = try #require(context.run.inspect(at: context.workspace, checkFingerprint: false, javaEntrypoints: nil).projectToolchain)
        #expect(toolchain.javaHomePath == canonical.javaHomePath)
        #expect(toolchain.pathOverrides["a"] == .init(mavenExecutablePath: "./mvnw", mavenJavaHomePath: "/fixture/a-jdk"))
        #expect(toolchain.pathOverrides["b"] == .init())
        #expect(!context.storage.fileExists(at: context.portable))
        #expect(!context.storage.fileExists(at: context.local("a")))
        #expect(!context.storage.fileExists(at: context.local("b")))
        #expect(context.storage.fileExists(at: context.local("temporarily-absent")))
        let bytes = try context.options.projectDocument(context.workspace).bytes
        #expect(!(try context.migration().migrate(workspace: context.workspace, reactorRoots: ["a", "b"])))
        #expect(try context.options.projectDocument(context.workspace).bytes == bytes)
        #expect(try context.migration().migrate(workspace: context.workspace, reactorRoots: ["temporarily-absent"]))
        #expect(try context.options.instanceOptions(workspaceURL: context.workspace, buildSystemID: "maven")["temporarily-absent"]?["settingsFile"] == .string("/fixture/absent.xml"))
        #expect(!context.storage.fileExists(at: context.local("temporarily-absent")))
        #expect(context.preferences.migrationReceipts.isEmpty)
    }

    @Test(arguments: [false, true])
    func rootReactorUsesProjectDefaultsAndPreservesAnExplicitCanonicalAutomaticChoice(existing: Bool) throws {
        let context = try Context()
        defer { context.clean() }
        try context.legacy.saveMavenConfiguration(.init(portable: nil, local: .init(mavenExecutablePath: "./mvnw", javaHomePath: "/fixture/legacy-jdk")), workspaceURL: context.workspace, reactorPath: ".")
        if existing { try context.run.saveProjectToolchain(ProjectToolchainSelection(), at: context.workspace) }
        #expect(try context.migration().migrate(workspace: context.workspace, reactorRoots: ["."]))
        let saved = try #require(context.run.inspect(at: context.workspace, checkFingerprint: false, javaEntrypoints: nil).projectToolchain)
        #expect(saved.mavenExecutablePath == (existing ? "" : "./mvnw"))
        #expect(saved.mavenJavaHomePath == (existing ? "" : "/fixture/legacy-jdk"))
        #expect(saved.pathOverrides.isEmpty)
    }

    @Test
    func portableChoicesDoNotReadOrRepairAnUnrelatedInvalidRunDocument() throws {
        let context = try Context()
        defer { context.clean() }
        try context.legacy.saveMavenConfiguration(.init(portable: .init(selectedProfiles: ["ci"]), local: .init(settingsPath: "/fixture/settings.xml")), workspaceURL: context.workspace, reactorPath: ".")
        let run = context.workspace.appendingPathComponent(".lithe/run/local.json")
        try context.storage.createDirectory(at: run.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{unrelated broken run configuration".utf8)
        try original.write(to: run)
        #expect(try context.migration().migrate(workspace: context.workspace, reactorRoots: ["."]))
        #expect(try Data(contentsOf: run) == original)
        #expect(!context.storage.fileExists(at: context.portable))
        #expect(try context.options.instanceOptions(workspaceURL: context.workspace, buildSystemID: "maven")["."]?["settingsFile"] == .string("/fixture/settings.xml"))
    }

    @Test
    func oversizedRootInventoryRetainsSourcesBeforeAnyTargetPublication() throws {
        let context = try Context()
        defer { context.clean() }
        try context.legacy.saveMavenConfiguration(.init(portable: .init(selectedProfiles: ["ci"]), local: nil), workspaceURL: context.workspace, reactorPath: ".")
        let original = try Data(contentsOf: context.portable)
        #expect(throws: (any Error).self) {
            try context.migration().migrate(workspace: context.workspace, reactorRoots: (0..<257).map { "root-\($0)" })
        }
        #expect(try Data(contentsOf: context.portable) == original)
        #expect(context.preferences.migrationReceipts.isEmpty)
        #expect(!context.storage.fileExists(at: context.workspace.appendingPathComponent(".lithe/build/options.json")))
    }

    @Test
    func partialPublicationCanRetryWithoutRemovingAnyUnverifiedSource() throws {
        let context = try Context()
        defer { context.clean() }
        try context.legacy.saveMavenConfiguration(.init(portable: .init(selectedProfiles: ["ci"], customProfiles: ["later"], skipTests: true), local: .init(settingsPath: "/fixture/settings.xml", mavenExecutablePath: "./mvnw")), workspaceURL: context.workspace, reactorPath: ".")
        let original = try Data(contentsOf: context.portable)
        let local = try Data(contentsOf: context.local("."))
        var failing = context.storage
        failing.failRunPublication = true
        #expect(throws: (any Error).self) { try context.migration(storage: failing).migrate(workspace: context.workspace, reactorRoots: ["."]) }
        #expect(try Data(contentsOf: context.portable) == original)
        #expect(try Data(contentsOf: context.local(".")) == local)
        #expect(!context.preferences.migrationReceipts.isEmpty)
        #expect(try context.options.projectDocument(context.workspace).document.systems["maven"]?.instanceDefaults["profiles"] == .array([.string("ci")]))
        #expect(try context.migration().migrate(workspace: context.workspace, reactorRoots: ["."]))
        #expect(!context.storage.fileExists(at: context.portable))
        #expect(!context.storage.fileExists(at: context.local(".")))
        #expect(context.preferences.migrationReceipts.isEmpty)
    }

    @Test
    func anExternalSourceEditAtRemovalIsRetainedAndCannotBeErasedOnRetry() throws {
        let context = try Context()
        defer { context.clean() }
        try context.legacy.saveMavenConfiguration(.init(portable: .init(selectedProfiles: ["old"]), local: nil), workspaceURL: context.workspace, reactorPath: ".")
        let changed = try JSONEncoder().encode(MavenPortableConfiguration(selectedProfiles: ["external-after-publication"]))
        let source = context.portable
        var racing = context.storage
        racing.beforeRemoval = { url in if url == source { try changed.write(to: url) } }
        #expect(throws: (any Error).self) { try context.migration(storage: racing).migrate(workspace: context.workspace, reactorRoots: ["."]) }
        #expect(try Data(contentsOf: context.portable) == changed)
        #expect(throws: (any Error).self) { try context.migration().migrate(workspace: context.workspace, reactorRoots: ["."]) }
        #expect(try Data(contentsOf: context.portable) == changed)
        #expect(!context.preferences.migrationReceipts.isEmpty)
    }

    @Test(arguments: ["unknown", "future-version", "corrupt", "outside-link"])
    func invalidOrUnownedLegacySourcesNeverCreateDestinations(kind: String) throws {
        let context = try Context()
        defer { context.clean() }
        try context.storage.createDirectory(at: context.portable.deletingLastPathComponent(), withIntermediateDirectories: true)
        var value: [String: Any] = ["version": 1, "selectedProfiles": [], "customProfiles": [], "skipTests": false]
        if kind == "unknown" { value["futureOption"] = "keep me" }
        if kind == "future-version" { value["version"] = 2 }
        let bytes = kind == "corrupt" ? Data("{broken".utf8) : try JSONSerialization.data(withJSONObject: value)
        if kind == "outside-link" {
            let outside = context.root.appendingPathComponent("outside.json")
            try bytes.write(to: outside)
            try FileManager.default.createSymbolicLink(at: context.portable, withDestinationURL: outside)
        } else { try bytes.write(to: context.portable) }
        #expect(throws: (any Error).self) { try context.migration().migrate(workspace: context.workspace, reactorRoots: ["."]) }
        #expect(try Data(contentsOf: context.portable) == bytes)
        #expect(!context.storage.fileExists(at: context.workspace.appendingPathComponent(".lithe/build/options.json")))
        #expect(!context.storage.fileExists(at: context.workspace.appendingPathComponent(".lithe/run/local.json")))
        #expect(context.preferences.migrationReceipts.isEmpty)
    }

    @MainActor
    private struct Context {
        let root: URL
        let workspace: URL
        let storage: MigrationFileStorage
        let preferences = MigrationPreferences()
        let options: MacBuildOptionsStore
        let run: MacRunConfigurationStore
        var legacy: MacMavenConfigurationStore { .init(storage: storage) }
        var portable: URL { workspace.appendingPathComponent(".lithe/maven/config.json") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("maven-configuration-transfer-" + UUID().uuidString).resolvingSymlinksInPath()
            workspace = root.appendingPathComponent("workspace")
            storage = MigrationFileStorage(root: root)
            try storage.createDirectory(at: workspace, withIntermediateDirectories: true)
            options = MacBuildOptionsStore(store: preferences, storage: storage)
            run = MacRunConfigurationStore(core: RustCoreBridge(), storage: storage, preferences: preferences)
        }
        func migration(storage replacement: MigrationFileStorage? = nil) -> MacLegacyMavenConfigurationMigration {
            let storage = replacement ?? storage
            return MacLegacyMavenConfigurationMigration(storage: storage, preferences: preferences,
                runStore: MacRunConfigurationStore(core: RustCoreBridge(), storage: storage, preferences: preferences),
                options: MacBuildOptionsStore(store: preferences, storage: storage), immutableRoots: [Bundle.main.bundleURL])
        }
        func local(_ path: String) -> URL {
            let digest = SHA256.hash(data: Data((workspace.path + "\0" + path).utf8)).map { String(format: "%02x", $0) }.joined()
            return storage.applicationSupportDirectory().appendingPathComponent("Lithe/Maven/" + digest + ".json")
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class MigrationPreferences: KeyValueStore {
    private var values: [String: Any] = [:]
    var migrationReceipts: [String] { values.keys.filter { $0.hasPrefix("BuildSystems.Migrations.Maven.") } }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct MigrationFileStorage: FileStorage {
    let root: URL
    var failRunPublication = false
    var beforeRemoval: (@Sendable (URL) throws -> Void)?
    private let native = MacFileStorage()
    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root.appendingPathComponent("cache") }
    func applicationSupportDirectory() -> URL { root.appendingPathComponent("support") }
    func temporaryDirectory() -> URL { root.appendingPathComponent("temporary") }
    func metadata(for url: URL) -> FileMetadata? { native.metadata(for: url) }
    func fileExists(at url: URL) -> Bool { native.fileExists(at: url) }
    func isExecutable(at url: URL) -> Bool { native.isExecutable(at: url) }
    func listDirectory(at url: URL) -> [URL] { native.listDirectory(at: url) }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data { try native.readPrefix(from: url, byteCount: byteCount) }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { try native.readData(from: url, options: options) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try native.writeData(data, to: url, options: options) }
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        if failRunPublication && url.lastPathComponent == "local.json" { throw CocoaError(.fileWriteNoPermission) }
        return try native.replaceData(data, at: url, expecting: expected)
    }
    func replaceDataPreservingMetadata(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool { try native.replaceDataPreservingMetadata(data, at: url, expecting: expected) }
    func removeData(at url: URL, expecting expected: Data) throws -> Bool {
        try beforeRemoval?(url)
        return try native.removeData(at: url, expecting: expected)
    }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try native.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func removeItem(at url: URL) throws { try native.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try native.moveItem(at: sourceURL, to: destinationURL) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { try native.copyItem(at: sourceURL, to: destinationURL) }
}
