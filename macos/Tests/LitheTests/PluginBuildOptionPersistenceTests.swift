import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI
import Testing
@testable import Lithe

/// Uses real Core resolution and argv expansion, plus the production preferences
/// adapter. A sibling's valid choice must not resurrect a cleared default.
@Suite("Plugin build option persistence")
@MainActor
struct PluginBuildOptionPersistenceTests {
    @Test
    func nativeDocumentValidationConsumesTheSameCoreFixtureAsWindows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/build-project-options/validation.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        for item in cases {
            let document = try #require(item["document"]), expected = try #require(item["valid"] as? Bool)
            var valid = true
            do { try BuildProjectOptionsDocument.validate(document) } catch { valid = false }
            #expect(valid == expected, Comment(rawValue: String(describing: item["name"])))
        }
    }

    @Test
    func privateDefaultsReachPlansAndResetWithoutChangingTheTeamDocument() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-private-build-defaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace, instanceScoped: true)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing, storage: MacFileStorage())
        var document = BuildProjectOptionsDocument()
        var system = BuildProjectOptionsDocument.System()
        system.instanceDefaults["settingsFile"] = .string("/fixture/team.xml")
        system.instances["b"] = ["settingsFile": .string("/fixture/team-b.xml")]
        document.systems["cargo"] = system
        try store.saveProjectDocument(document, workspace: workspace, expecting: nil)
        let bytes = try store.projectDocument(workspace).bytes
        try store.setInstanceDefaults(["settingsFile": .string("/fixture/private.xml")], workspaceURL: workspace, buildSystemID: "cargo")
        let runner = OptionCommandRecorder()
        let service = Self.service(source: source, workspace: workspace, store: store, runner: runner)
        defer { service.stop() }
        _ = try await Self.refreshed(service) { service.reset(workspaceURL: workspace) }
        #expect(service.entry("cargo:a")?.options.first { $0.id == "settingsFile" }?.value == .string("/fixture/private.xml"))
        #expect(service.entry("cargo:b")?.options.first { $0.id == "settingsFile" }?.value == .string("/fixture/team-b.xml"))
        #expect(Array(try await Self.run("cargo:a", service: service, runner: runner).suffix(2)) == ["--config", "/fixture/private.xml"])
        _ = try service.configureOption("cargo:a", optionID: "settingsFile", value: .string(""))
        #expect(try service.configureOption("cargo:a", optionID: "settingsFile", value: nil).value == .string("/fixture/private.xml"))
        #expect(backing.instanceData.isEmpty)
        try store.setInstanceDefaults(["settingsFile": .string("/fixture/team.xml")], workspaceURL: workspace, buildSystemID: "cargo")
        _ = try await Self.refreshed(service) { service.detect() }
        #expect(service.entry("cargo:a")?.options.first { $0.id == "settingsFile" }?.value == .string("/fixture/team.xml"))
        #expect(try store.projectDocument(workspace).bytes == bytes)
    }

    @Test
    func sharedDefaultsStayInTheProjectWhileLocalEditsOnlyStoreDifferences() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-shared-build-options-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace, instanceScoped: true, allowCustom: true)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing, storage: MacFileStorage())
        var shared = BuildProjectOptionsDocument()
        var system = BuildProjectOptionsDocument.System()
        system.instanceDefaults = ["features": .array([.string("base")]), "settingsFile": .string("/fixture/shared.xml")]
        system.options = ["offline": .bool(true)]
        system.savedChoices = ["features": ["custom-unselected", "base"]]
        shared.systems["cargo"] = system
        try store.saveProjectDocument(shared, workspace: workspace, expecting: nil)
        let original = try store.projectDocument(workspace).bytes
        let runner = OptionCommandRecorder()
        let service = Self.service(source: source, workspace: workspace, store: store, runner: runner)
        defer { service.stop() }
        _ = try await Self.refreshed(service) { service.reset(workspaceURL: workspace) }
        #expect(service.entries.allSatisfy { $0.options.first { $0.id == "settingsFile" }?.value == .string("/fixture/shared.xml") })
        #expect(try store.projectDocument(workspace).bytes == original)
        #expect(backing.instanceData.isEmpty)
        #expect(service.entry("cargo:a")?.options.first { $0.id == "features" }?.choices.contains { $0.value == "custom-unselected" } == true)
        #expect(service.entry("cargo:a")?.options.first { $0.id == "features" }?.value == .array([.string("base")]))
        _ = try await Self.refreshed(service) {
            service.setInstanceOption("cargo:a", optionID: "settingsFile", value: .string("/fixture/local-a.xml"))
        }
        #expect(service.entry("cargo:b")?.options.first { $0.id == "settingsFile" }?.value == .string("/fixture/shared.xml"))
        #expect(try store.projectDocument(workspace).bytes == original)
        let localData = try #require(backing.instanceData.first)
        let local = try JSONDecoder().decode([String: [String: ToolingJSONValue]].self, from: localData)
        #expect(local == ["a": ["settingsFile": .string("/fixture/local-a.xml")]])
        let reset = try service.configureOption("cargo:a", optionID: "settingsFile", value: nil)
        #expect(reset.value == .string("/fixture/shared.xml"))
        #expect(backing.instanceData.isEmpty)
        #expect(try store.projectDocument(workspace).bytes == original)
        var changed = shared
        changed.systems["cargo"]?.instanceDefaults["settingsFile"] = .string("/fixture/new-shared.xml")
        try store.saveProjectDocument(changed, workspace: workspace, expecting: original)
        #expect(throws: (any Error).self) { try store.saveProjectDocument(shared, workspace: workspace, expecting: original) }
        _ = try await Self.refreshed(service) { service.detect() }
        #expect(service.entries.allSatisfy { $0.options.first { $0.id == "settingsFile" }?.value == .string("/fixture/new-shared.xml") })
        #expect(try await Self.run("cargo:a", service: service, runner: runner) == ["build", "--message-format=short", "--features", "base", "--offline", "--config", "/fixture/new-shared.xml"])
    }

    @Test
    func malformedSharedAndLocalOptionsNeverBecomeEmptySuccessfulInput() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-invalid-build-options-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing, storage: MacFileStorage())
        var project = BuildProjectOptionsDocument()
        project.systems["cargo"] = BuildProjectOptionsDocument.System()
        try store.saveProjectDocument(project, workspace: workspace, expecting: nil)
        let url = workspace.appendingPathComponent(".lithe/build/options.json")
        for invalid in ["1", "null", "{}", "[true]"] {
            let json = Data("{\"version\":1,\"systems\":{\"cargo\":{\"instanceDefaults\":{\"features\":\(invalid)}}}}".utf8)
            try json.write(to: url)
            #expect(throws: (any Error).self) { try store.projectDocument(workspace) }
            #expect(try Data(contentsOf: url) == json)
        }
        try Data("{\"version\":true,\"systems\":{}}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.projectDocument(workspace) }
        let broken = Data("{broken".utf8)
        try broken.write(to: url)
        let service = Self.service(source: source, workspace: workspace, store: store, runner: OptionCommandRecorder())
        defer { service.stop() }
        service.reset(workspaceURL: workspace)
        await #expect(throws: (any Error).self) { try await service.prepareLanguageImport(workspaceURL: workspace) }
        #expect(service.entries.isEmpty)
        #expect(!service.issues.isEmpty)
        #expect(try Data(contentsOf: url) == broken)
        try FileManager.default.removeItem(at: url)
        try store.setOptions(["offline": .bool(true)], workspaceURL: workspace, buildSystemID: "cargo")
        backing.corruptBuildOptions()
        #expect(throws: (any Error).self) { try store.options(workspaceURL: workspace, buildSystemID: "cargo") }
    }

    @Test(arguments: ["", ".Instances", ".InstanceDefaults", ".EmptyMultiSelect"])
    func nonDataLocalPreferencesBlockDetectionWithoutReplacingTheirSource(suffix: String) async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-invalid-option-type-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace)
        let backing = OptionPreferenceStore()
        let key = "BuildSystems.Options.cargo." + MacPluginStateDirectories.workspaceDigest(workspace) + suffix
        backing.set("retain the malformed preference", forKey: key)
        let store = MacBuildOptionsStore(store: backing)
        let service = Self.service(source: source, workspace: workspace, store: store, runner: OptionCommandRecorder())
        defer { service.stop() }
        service.reset(workspaceURL: workspace)
        await #expect(throws: (any Error).self) { try await service.prepareLanguageImport(workspaceURL: workspace) }
        #expect(service.entries.isEmpty)
        #expect(!service.issues.isEmpty)
        #expect(backing.object(forKey: key) as? String == "retain the malformed preference")
    }

    @Test
    func scopeUpgradeMigratesSharedValuesAndEmptyMarkersOnlyAfterReadback() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-build-scope-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace, instanceScoped: true)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing)
        let previous: [String: ToolingJSONValue] = ["features": .array([.string("cli"), .string("gui")]), "settingsFile": .string("/fixture/shared.xml"), "offline": .bool(true)]
        try store.setOptions(previous, workspaceURL: workspace, buildSystemID: "cargo")
        try store.setEmptyMultiSelectOptions(["a": ["features"], "temporarily-absent": ["features"]], workspaceURL: workspace, buildSystemID: "cargo")
        try store.setInstanceOptions(["b": ["settingsFile": .string("/fixture/explicit b.xml")]], workspaceURL: workspace, buildSystemID: "cargo")
        backing.refuseInstanceWrites = true
        let service = Self.service(source: source, workspace: workspace, store: store, runner: OptionCommandRecorder())
        defer { service.stop() }
        service.reset(workspaceURL: workspace)
        do {
            _ = try await service.prepareLanguageImport(workspaceURL: workspace)
            Issue.record("A failed migration must block publishing an unrelated default configuration")
        } catch {
            #expect(!service.issues.isEmpty)
        }
        #expect(service.entries.isEmpty)
        #expect(try store.options(workspaceURL: workspace, buildSystemID: "cargo") == previous)
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo") == ["a": ["features"], "temporarily-absent": ["features"]])
        backing.refuseInstanceWrites = false
        let imported = try await Self.refreshed(service) { service.detect() }
        #expect(imported.mavenContext?.profiles == [])
        #expect(imported.mavenContext?.settingsPath == "/fixture/shared.xml")
        #expect(try store.options(workspaceURL: workspace, buildSystemID: "cargo") == ["offline": .bool(true)])
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["a"]?["features"] == .array([]))
        #expect(try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["temporarily-absent"]?["features"] == .array([]))
        #expect(try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["b"]?["features"] == .array([.string("gui")]))
        #expect(try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["b"]?["settingsFile"] == .string("/fixture/explicit b.xml"))
        _ = try await Self.refreshed(service) { service.detect() }
        #expect(try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["a"]?["features"] == .array([]))
    }

    @Test
    func independentInstanceOptionsSurviveSiblingEditsResetAndReopening() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-instance-build-options-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace, instanceScoped: true)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing)
        try store.setInstanceOptions([
            "a": ["features": .array([]), "settingsFile": .string("/fixture/a settings.xml"), "release": .bool(false), "label": .string("")],
            "b": ["features": .array([.string("gui")]), "settingsFile": .string("/fixture/b.xml"), "cacheDirectory": .string("/fixture/cache b")]
        ], workspaceURL: workspace, buildSystemID: "cargo")
        let runner = OptionCommandRecorder()
        let service = Self.service(source: source, workspace: workspace, store: store, runner: runner)
        defer { service.stop() }
        let imported = try await Self.refreshed(service) { service.reset(workspaceURL: workspace) }
        #expect(imported.mavenContext?.profiles == [])
        #expect(imported.mavenContext?.settingsPath == "/fixture/a settings.xml")
        #expect(service.entry("cargo:a")?.options.first { $0.id == "features" }?.scope == .instance)
        #expect(try await Self.run("cargo:a", service: service, runner: runner) == ["build", "--message-format=short", "--config", "/fixture/a settings.xml"])
        #expect(try await Self.run("cargo:b", service: service, runner: runner) == ["build", "--message-format=short", "--features", "gui", "--config", "/fixture/b.xml", "--cache", "/fixture/cache b"])
        let originalA = try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["a"]
        _ = try await Self.refreshed(service) {
            service.setInstanceOption("cargo:b", optionID: "features", value: .array([]))
            service.setInstanceOption("cargo:b", optionID: "settingsFile", value: .string("/fixture/changed b.xml"))
        }
        #expect(try store.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["a"] == originalA)
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(try store.options(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(throws: (any Error).self) { try service.configureOption("cargo:a", optionID: "release", value: .string("bad")) }
        service.stop()

        let reopenedStore = MacBuildOptionsStore(store: backing)
        let reopened = Self.service(source: source, workspace: workspace, store: reopenedStore, runner: runner)
        defer { reopened.stop() }
        _ = try await Self.refreshed(reopened) { reopened.reset(workspaceURL: workspace) }
        #expect(reopened.entry("cargo:a")?.options.first { $0.id == "features" }?.value == .array([]))
        #expect(reopened.entry("cargo:a")?.options.first { $0.id == "label" }?.source == "user")
        #expect(reopened.entry("cargo:a")?.options.first { $0.id == "release" }?.source == "user")
        #expect(reopened.entry("cargo:b")?.options.first { $0.id == "features" }?.value == .array([]))
        _ = try await Self.refreshed(reopened) {
            reopened.setInstanceOption("cargo:a", optionID: "features", value: nil)
            reopened.setOption("cargo:a", optionID: "settingsFile", value: nil)
            reopened.setOption("cargo:a", optionID: "offline", value: .bool(true))
        }
        #expect(reopened.entry("cargo:a")?.options.first { $0.id == "features" }?.value == .array([.string("base")]))
        #expect(reopened.entry("cargo:b")?.options.first { $0.id == "features" }?.value == .array([]))
        #expect(try reopenedStore.instanceOptions(workspaceURL: workspace, buildSystemID: "cargo")["b"]?["settingsFile"] == .string("/fixture/changed b.xml"))
        #expect(reopened.entries.allSatisfy { $0.options.first { $0.id == "offline" }?.value == .bool(true) })
        #expect(try reopenedStore.instanceOptions(workspaceURL: workspace.appendingPathComponent("other"), buildSystemID: "cargo").isEmpty)
        #expect(try reopenedStore.instanceOptions(workspaceURL: workspace, buildSystemID: "other").isEmpty)
    }

    @Test
    func checkedOptionEditsRejectInvalidValuesAndReadBackTheInstanceWithoutChangingSiblings() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-checked-build-options-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace)
        let store = MacBuildOptionsStore(store: OptionPreferenceStore())
        let service = Self.service(source: source, workspace: workspace, store: store, runner: OptionCommandRecorder())
        defer { service.stop() }
        _ = try await Self.refreshed(service) { service.reset(workspaceURL: workspace) }
        #expect(throws: (any Error).self) { try service.configureOption("cargo:a", optionID: "features", value: .bool(true)) }
        #expect(throws: (any Error).self) { try service.configureOption("cargo:a", optionID: "features", value: .array([.string("absent")])) }
        #expect(throws: (any Error).self) { try service.configureOption("cargo:a", optionID: "missing", value: .string("v")) }
        #expect(try store.options(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        let changed = try service.configureOption("cargo:a", optionID: "features", value: .array([.string("cli")]))
        #expect(changed.value == .array([.string("cli")]))
        #expect(changed.source == "user")
        let cleared = try service.configureOption("cargo:a", optionID: "features", value: .array([]))
        #expect(cleared.value == .array([]))
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo")["a"] == ["features"])
        let reset = try service.configureOption("cargo:a", optionID: "features", value: nil)
        #expect(reset.value == .array([.string("base")]))
        #expect(reset.source != "user")
    }

    @Test
    func clearedInstanceSurvivesSiblingEditsRedetectionAndReopening() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing)
        try store.setOptions(
            ["features": .array([.string("cli"), .string("gui")])],
            workspaceURL: workspace, buildSystemID: "cargo"
        )
        let runner = OptionCommandRecorder()
        let service = Self.service(source: source, workspace: workspace, store: store, runner: runner)
        defer { service.stop() }
        _ = try await Self.refreshed(service) { service.reset(workspaceURL: workspace) }
        let a = try #require(service.entry("cargo:a"))
        let b = try #require(service.entry("cargo:b"))
        #expect(a.options.first { $0.id == "features" }?.value == .array([.string("cli")]))
        #expect(b.options.first { $0.id == "features" }?.value == .array([.string("gui")]))

        // Non-empty, wholly invalid values fall back to the declaration default
        // in real Core. Only a genuine [] is an explicit user selection.
        let operations = RustBuildSystemOperations(core: RustCoreBridge())
        let fallback = try operations.resolveOptions(
            a.target, options: ["features": .array([.string("gui")])], modelValues: a.model?.optionValues
        )
        #expect(fallback.options.first { $0.id == "features" }?.source == "default")
        #expect(fallback.options.first { $0.id == "features" }?.value == .array([.string("base")]))
        let previousFingerprint = a.sync?.fingerprint
        let cleared = try await Self.refreshed(service) {
            service.setInstanceOption("cargo:a", optionID: "features", value: .array([]))
        }
        #expect(cleared.mavenContext?.profiles == [])
        #expect(try store.options(workspaceURL: workspace, buildSystemID: "cargo")["features"] == .array([.string("gui")]))
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo") == ["a": ["features"]])
        #expect(service.entry("cargo:a")?.options.first { $0.id == "features" }?.source == "user")
        #expect(service.entry("cargo:a")?.options.first { $0.id == "features" }?.value == .array([]))
        #expect(service.entry("cargo:a")?.sync?.fingerprint != previousFingerprint)
        #expect(try await Self.run("cargo:a", service: service, runner: runner) == ["build", "--message-format=short"])
        #expect(try await Self.run("cargo:b", service: service, runner: runner) == ["build", "--message-format=short", "--features", "gui"])

        // A sibling selecting a value also accepted by A must not undo A's clear.
        _ = try await Self.refreshed(service) {
            service.setInstanceOption("cargo:b", optionID: "features", value: .array([.string("base")]))
        }
        #expect(try await Self.run("cargo:a", service: service, runner: runner) == ["build", "--message-format=short"])
        service.stop()

        // Recreate both service and adapter, retaining only persisted preferences.
        let reopenedStore = MacBuildOptionsStore(store: backing)
        let reopened = Self.service(source: source, workspace: workspace, store: reopenedStore, runner: runner)
        defer { reopened.stop() }
        let imported = try await Self.refreshed(reopened) { reopened.reset(workspaceURL: workspace) }
        #expect(imported.mavenContext?.profiles == [])
        #expect(try await Self.run("cargo:a", service: reopened, runner: runner) == ["build", "--message-format=short"])
        #expect(try await Self.run("cargo:b", service: reopened, runner: runner) == ["build", "--message-format=short", "--features", "base"])

        _ = try await Self.refreshed(reopened) {
            reopened.setInstanceOption("cargo:a", optionID: "features", value: .array([.string("cli")]))
        }
        #expect(try reopenedStore.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(try await Self.run("cargo:a", service: reopened, runner: runner) == ["build", "--message-format=short", "--features", "base,cli"])
        _ = try await Self.refreshed(reopened) {
            reopened.setInstanceOption("cargo:a", optionID: "features", value: .array([]))
        }
        let reset = try await Self.refreshed(reopened) {
            reopened.setInstanceOption("cargo:a", optionID: "features", value: nil)
        }
        #expect(try reopenedStore.options(workspaceURL: workspace, buildSystemID: "cargo")["features"] == nil)
        #expect(try reopenedStore.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(reset.mavenContext?.profiles == ["base"])
        #expect(try await Self.run("cargo:a", service: reopened, runner: runner) == ["build", "--message-format=short", "--features", "base"])
    }

    @Test
    func emptySelectionsRoundTripWithoutChangingLegacyOptionsAndRemainScoped() throws {
        let backing = OptionPreferenceStore()
        let workspace = URL(fileURLWithPath: "/fixture/workspace")
        let other = URL(fileURLWithPath: "/fixture/other")
        let store = MacBuildOptionsStore(store: backing)
        let legacy: [String: ToolingJSONValue] = ["features": .array([.string("gui")]), "text": .string("")]
        try store.setOptions(legacy, workspaceURL: workspace, buildSystemID: "cargo")
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        try store.setEmptyMultiSelectOptions(["a": ["features"], "unused": []], workspaceURL: workspace, buildSystemID: "cargo")
        let reopened = MacBuildOptionsStore(store: backing)
        #expect(try reopened.options(workspaceURL: workspace, buildSystemID: "cargo") == legacy)
        #expect(try reopened.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo") == ["a": ["features"]])
        #expect(try reopened.emptyMultiSelectOptions(workspaceURL: other, buildSystemID: "cargo").isEmpty)
        #expect(try reopened.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "other").isEmpty)
        try reopened.setEmptyMultiSelectOptions([:], workspaceURL: workspace, buildSystemID: "cargo")
        #expect(try store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(try store.options(workspaceURL: workspace, buildSystemID: "cargo") == legacy)
    }

    private static func refreshed(
        _ service: BuildSystemService, action: () -> Void
    ) async throws -> JavaLanguageImportConfiguration {
        let published = TestGate()
        service.onLanguageImportChanged = { _ in published.open() }
        defer { service.onLanguageImportChanged = nil }
        action()
        try #require(await published.waitUntilOpen(timeout: .seconds(5)), "Detection/import did not finish")
        return try #require(service.languageImport)
    }

    private static func run(
        _ id: String, service: BuildSystemService, runner: OptionCommandRecorder
    ) async throws -> [String] {
        let entry = try #require(service.entry(id))
        let project = try #require(entry.model?.projects.first)
        let ended = TestGate()
        let observation = service.runEnded.sink { _ in ended.open() }
        defer { observation.cancel(); service.stopRun() }
        try #require(service.runTask(id, request: BuildTaskRequest(task: "build", project: BuildSelection(project: project)), title: "Build"))
        try #require(await ended.waitUntilOpen(timeout: .seconds(5)), "Build did not finish")
        #expect(service.runState == .succeeded)
        return try #require(await runner.requests.last).arguments
    }

    private static func service(
        source: BuildSystemPluginSource, workspace: URL, store: MacBuildOptionsStore, runner: OptionCommandRecorder
    ) -> BuildSystemService {
        BuildSystemService(
            planner: RustBuildSystemOperations(core: RustCoreBridge()), tools: OptionToolResolver(), optionsStore: store,
            stateLocator: OptionStateLocator(root: workspace), runner: runner, sources: { [source] }
        )
    }

    private static func source(workspace: URL, instanceScoped: Bool = false, allowCustom: Bool = false) throws -> BuildSystemPluginSource {
        for (root, feature) in [("a", "cli"), ("b", "gui")] {
            let directory = workspace.appendingPathComponent(root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("[package]\nname = \"\(root)\"\nversion = \"0.1.0\"\n[features]\n\(feature) = []\n".utf8)
                .write(to: directory.appendingPathComponent("Cargo.toml"))
        }
        let fixture = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(instanceScoped ? "build-instance-options" : "build-static-file").plugin.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var systems = try #require(manifest["buildSystems"] as? [[String: Any]])
        var options = try #require(systems[0]["options"] as? [[String: Any]])
        let index = try #require(options.firstIndex { $0["id"] as? String == "features" })
        options[index]["choices"] = [["value": "base"]]
        options[index]["default"] = ["base"]
        options[index]["allowCustom"] = allowCustom
        systems[0]["options"] = options
        systems[0]["languageImport"] = ["kind": "maven", "options": ["profiles": "features"]]
        if instanceScoped {
            systems[0]["languageImport"] = ["kind": "maven", "options": ["profiles": "features", "settingsFile": "settingsFile"]]
        }
        manifest["buildSystems"] = systems
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: JSONSerialization.data(withJSONObject: manifest))
        return BuildSystemPluginSource(
            pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: fixture.deletingLastPathComponent(), buildSystems: descriptor.buildSystems
        )
    }
}

private final class OptionPreferenceStore: KeyValueStore {
    private var values: [String: Any] = [:]
    var refuseInstanceWrites = false
    var instanceData: [Data] { values.filter { $0.key.hasSuffix(".Instances") }.values.compactMap { $0 as? Data } }
    func corruptBuildOptions() {
        for key in values.keys where key.hasPrefix("BuildSystems.Options.") { values[key] = Data("{broken".utf8) }
    }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) {
        guard !refuseInstanceWrites || !key.hasSuffix(".Instances") else { return }
        values[key] = value
    }
}

private actor OptionCommandRecorder: BuildCommandRunning {
    private(set) var requests: [BuildCommandRequest] = []
    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> BuildCommandResult {
        requests.append(request)
        return BuildCommandResult(termination: .exited(0))
    }
}

@MainActor
private final class OptionToolResolver: BuildToolResolving {
    func resolve(
        _ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: URL(fileURLWithPath: "/fixture/bin/tool"), environment: [:], executesProjectCode: false, version: nil)
    }
}

private struct OptionStateLocator: BuildSystemStateLocating {
    let root: URL
    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL { root }
    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL { workspaceStateDirectory.appendingPathComponent(UUID().uuidString) }
    func removeOutputFile(_ url: URL) {}
}
