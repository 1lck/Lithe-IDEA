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
    func clearedInstanceSurvivesSiblingEditsRedetectionAndReopening() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source(workspace: workspace)
        let backing = OptionPreferenceStore()
        let store = MacBuildOptionsStore(store: backing)
        store.setOptions(
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
        #expect(store.options(workspaceURL: workspace, buildSystemID: "cargo")["features"] == .array([.string("gui")]))
        #expect(store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo") == ["a": ["features"]])
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
        #expect(reopenedStore.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(try await Self.run("cargo:a", service: reopened, runner: runner) == ["build", "--message-format=short", "--features", "base,cli"])
        _ = try await Self.refreshed(reopened) {
            reopened.setInstanceOption("cargo:a", optionID: "features", value: .array([]))
        }
        let reset = try await Self.refreshed(reopened) {
            reopened.setInstanceOption("cargo:a", optionID: "features", value: nil)
        }
        #expect(reopenedStore.options(workspaceURL: workspace, buildSystemID: "cargo")["features"] == nil)
        #expect(reopenedStore.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(reset.mavenContext?.profiles == ["base"])
        #expect(try await Self.run("cargo:a", service: reopened, runner: runner) == ["build", "--message-format=short", "--features", "base"])
    }

    @Test
    func emptySelectionsRoundTripWithoutChangingLegacyOptionsAndRemainScoped() {
        let backing = OptionPreferenceStore()
        let workspace = URL(fileURLWithPath: "/fixture/workspace")
        let other = URL(fileURLWithPath: "/fixture/other")
        let store = MacBuildOptionsStore(store: backing)
        let legacy: [String: ToolingJSONValue] = ["features": .array([.string("gui")]), "text": .string("")]
        store.setOptions(legacy, workspaceURL: workspace, buildSystemID: "cargo")
        #expect(store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        store.setEmptyMultiSelectOptions(["a": ["features"], "unused": []], workspaceURL: workspace, buildSystemID: "cargo")
        let reopened = MacBuildOptionsStore(store: backing)
        #expect(reopened.options(workspaceURL: workspace, buildSystemID: "cargo") == legacy)
        #expect(reopened.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo") == ["a": ["features"]])
        #expect(reopened.emptyMultiSelectOptions(workspaceURL: other, buildSystemID: "cargo").isEmpty)
        #expect(reopened.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "other").isEmpty)
        reopened.setEmptyMultiSelectOptions([:], workspaceURL: workspace, buildSystemID: "cargo")
        #expect(store.emptyMultiSelectOptions(workspaceURL: workspace, buildSystemID: "cargo").isEmpty)
        #expect(store.options(workspaceURL: workspace, buildSystemID: "cargo") == legacy)
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

    private static func source(workspace: URL) throws -> BuildSystemPluginSource {
        for (root, feature) in [("a", "cli"), ("b", "gui")] {
            let directory = workspace.appendingPathComponent(root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("[package]\nname = \"\(root)\"\nversion = \"0.1.0\"\n[features]\n\(feature) = []\n".utf8)
                .write(to: directory.appendingPathComponent("Cargo.toml"))
        }
        let fixture = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/cargo-build.plugin.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var systems = try #require(manifest["buildSystems"] as? [[String: Any]])
        var options = try #require(systems[0]["options"] as? [[String: Any]])
        let index = try #require(options.firstIndex { $0["id"] as? String == "features" })
        options[index]["choices"] = [["value": "base"]]
        options[index]["default"] = ["base"]
        options[index]["allowCustom"] = false
        systems[0]["options"] = options
        systems[0]["languageImport"] = ["kind": "maven", "options": ["profiles": "features"]]
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
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
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
