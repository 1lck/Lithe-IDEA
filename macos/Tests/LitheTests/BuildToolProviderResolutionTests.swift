import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import Testing
@testable import Lithe

/// Exercise the real Core plan, native resolver, and service together: an
/// earlier runtime failure must not let a provider discard a later selection.
@MainActor
struct BuildToolProviderResolutionTests {
    @Test(arguments: ["tool", "runtime", "empty"], ["missing", "old"])
    func runtimeFailurePreservesExplicitSelections(selection: String, failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("build.fixture"))
        if failure == "old" {
            let executable = root.appendingPathComponent("runtime")
            try Data("#!/bin/sh\nprintf 'runtime 1.0\\n'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let source = try Self.source(root: root)
        let settings: [String: ToolingJSONValue] = [
            "toolPath": .string(selection == "tool" ? root.appendingPathComponent("missing tool").path : ""),
            "runtimePath": .string(selection == "runtime" ? root.appendingPathComponent("missing runtime").path : "")
        ]
        let planner = RustBuildSystemOperations(core: RustCoreBridge())
        let runtime = ProjectRuntimeService(runtimeLocator: ProviderRuntimeLocator(root: root), store: ProviderEmptyStore())
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage())
        let target = BuildSystemTarget(manifest: source.manifest, buildSystemID: "fixture")
        let invocation = try planner.invocationPlan(target, root: ".", settings: settings)
        // Verify the exact review scenario: failure happens in the first,
        // automatic runtime, before any explicit candidate is inspected.
        do {
            _ = try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { id, output in
                try planner.checkToolVersion(target, runtime: id, output: output)
            }
            Issue.record("The prerequisite runtime must fail")
        } catch let error as BuildToolResolutionError {
            #expect(!error.terminal)
            #expect(error.message.contains("Prerequisite runtime"))
        }
        let providers = ProviderRequestRecorder()
        let service = BuildSystemService(
            planner: planner, tools: resolver, optionsStore: MacBuildOptionsStore(store: ProviderEmptyStore()),
            stateLocator: ProviderStateLocator(root: root), runner: ProviderUnexpectedCommandRunner(),
            providers: providers, settings: { _ in settings }, sources: { [source] }
        )
        defer { service.stop(); runtime.closeProject() }
        service.reset(workspaceURL: root)
        try #require(await Self.wait(service) { $0.first?.modelState == .notLoaded })
        let id = try #require(service.entries.first?.id)
        service.loadModel(id)
        try #require(await Self.wait(service) {
            if selection == "empty" { return $0.first?.modelState == .loaded }
            if case .failed = $0.first?.modelState { return true }
            return false
        })
        if selection == "empty" {
            #expect(providers.requests.count == 1)
            guard case .object(let params)? = providers.requests.first?.params else {
                Issue.record("A provider request must have object params")
                return
            }
            #expect(params["tool"] == nil)
        } else {
            #expect(providers.requests.isEmpty)
            guard case .failed(let message)? = service.entries.first?.modelState else { return }
            #expect(message.contains("Prerequisite runtime"))
        }
        service.loadDependencies(id, project: nil)
        try #require(await Self.wait(service) {
            if selection == "empty", case .loaded = $0.first?.dependencies["."] { return true }
            if selection != "empty", case .failed = $0.first?.dependencies["."] { return true }
            return false
        })
        if selection == "empty" {
            #expect(providers.requests.map(\.method) == ["lithe/build/model", "lithe/build/dependencies"])
            guard case .object(let params)? = providers.requests.last?.params else {
                Issue.record("A dependency request must have object params")
                return
            }
            #expect(params["tool"] == nil)
        } else {
            #expect(providers.requests.isEmpty)
            guard case .failed(let message)? = service.entries.first?.dependencies["."] else { return }
            #expect(message.contains("Prerequisite runtime"))
        }
    }

    private static func wait(_ service: BuildSystemService, until predicate: @escaping ([BuildSystemEntry]) -> Bool) async -> Bool {
        let finished = TestGate()
        let observation = service.$entries.sink { if predicate($0) { finished.open() } }
        defer { observation.cancel() }
        return await finished.waitUntilOpen(timeout: .seconds(5))
    }

    private static func source(root: URL) throws -> BuildSystemPluginSource {
        let fixture = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-tool-path.plugin.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        manifest["requires"] = ["buildSystems": 1, "buildProviders": 1, "executableResolution": 1, "settings": 2, "serverProcess": 1]
        manifest["permissions"] = ["process.build", "languageServer.launch"]
        var settings = try #require(manifest["settings"] as? [[String: Any]])
        settings.append(["id": "runtimePath", "type": "file", "title": "Runtime", "default": "", "scope": "global", "effect": "reload"])
        manifest["settings"] = settings
        var systems = try #require(manifest["buildSystems"] as? [[String: Any]])
        systems[0]["invocation"] = [
            "executables": [["kind": "setting", "settingID": "toolPath"]],
            "environmentInputs": ["FIXTURE_RUNTIME"],
            "runtimeDependencies": [
                ["id": "prerequisite", "displayName": "Prerequisite runtime", "minimumVersion": "2",
                 "executables": [["kind": "environment", "variable": "FIXTURE_RUNTIME", "path": "runtime"]],
                 "version": ["arguments": ["--version"], "pattern": "runtime ([0-9.]+)"]],
                ["id": "selected-runtime", "executables": [["kind": "setting", "settingID": "runtimePath"]]]
            ]
        ]
        systems[0]["model"] = ["source": "provider"]
        systems[0]["dependencies"] = ["source": "provider", "scopes": ["workspace"]]
        systems[0]["provider"] = ["launch": ["kind": "packaged", "path": "provider"], "executesProjectCode": false, "mayUseNetwork": false]
        manifest["buildSystems"] = systems
        let descriptor = try DeclarativePluginTestSupport.descriptor(manifest)
        return BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
                                       packageURL: root, buildSystems: descriptor.buildSystems)
    }
}

@MainActor
private final class ProviderRequestRecorder: BuildProviderRequesting {
    var requests: [BuildProviderRequest] = []
    func send(_ request: BuildProviderRequest, to target: BuildProviderTarget, timeout: Duration) async throws -> ToolingJSONValue {
        requests.append(request)
        if request.method == "lithe/build/dependencies" {
            return .object(["format": .string("litheDependencies"), "version": .integer(1), "dependencies": .array([])])
        }
        return .object(["format": .string("litheBuildModel"), "version": .integer(1),
                        "projects": .array([.object(["path": .string("."), "name": .string("fixture")])])])
    }
    func execute(
        _ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
        progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void
    ) async throws -> BuildProviderExecutionResult {
        _ = try await send(request, to: target, timeout: timeout)
        return BuildProviderExecutionResult(exitCode: 0, output: "")
    }

    func prepareRun(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                    progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> ToolingJSONValue {
        try await send(request, to: target, timeout: timeout)
    }
    func retainProviders(_ keep: (BuildProviderTarget) -> Bool) {}
}

private actor ProviderUnexpectedCommandRunner: BuildCommandRunning {
    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> BuildCommandResult {
        Issue.record("Provider loading must not run a build command")
        return BuildCommandResult(termination: .exited(1))
    }
}

private struct ProviderStateLocator: BuildSystemStateLocating {
    let root: URL
    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL { root }
    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL { root.appendingPathComponent(UUID().uuidString) }
    func removeOutputFile(_ url: URL) {}
}

private struct ProviderRuntimeLocator: RuntimeLocator {
    let root: URL
    func environment() -> [String: String] { ["FIXTURE_RUNTIME": root.path] }
    func discover() -> RuntimeDiscoveryResult { .init(javaRuntimes: [], mavenRuntimes: []) }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private struct ProviderEmptyStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}
