import Foundation
import Testing
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
@testable import Lithe

/// Opt-in integration using an explicitly supplied Node executable. All package
/// and state files are private test copies; cleanup waits for process release.
@MainActor
struct PluginHostProcessIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_PLUGIN_HOST_TEST_NODE"] != nil,
                   "Requires an explicit Node runtime for the real backend integration"))
    func commandRunsThroughCoreAndPublicHostWithoutMutatingThePackage() async throws {
        let node = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LITHE_PLUGIN_HOST_TEST_NODE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-host-process-\(UUID().uuidString)")
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        defer { contexts.close(owner: fixture.window) }
        let document = EditorDocument(url: fixture.url("sample.txt"), text: "saved", modificationDate: nil)
        document.text = "dirty 😀"
        let changed = TestGate()
        let surface = ProcessSurface(changed: changed)
        document.editorSurface = surface
        fixture.window.hostDocumentService = EditorDocumentService(windowID: fixture.windowID,
            workspaceURL: { PluginHostFixture.workspaceURL }, documents: { [document] }, activeDocumentID: { document.id }, languageIdentifier: { _ in nil })
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(PluginDocumentHostService(contexts: contexts))
        let repository = DeclarativePluginTestSupport.repositoryRoot
        let script = try Data(contentsOf: repository.appendingPathComponent("macos/Tests/LitheTests/Fixtures/PluginHostAPI/backend.mjs"))
        try script.write(to: package.appendingPathComponent("backend.mjs"))
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent(
            "shared/contracts/plugins/v1/fixtures/command-backend.plugin.json"))) as? [String: Any])
        manifest["backend"] = ["launch": ["kind": "runtime", "tool": "node", "entry": "backend.mjs"]]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: package.appendingPathComponent("plugin.json"))
        let core = RustCoreBridge()
        let operations = RustDeclarativePluginOperations(core: core)
        let descriptor = try operations.validate(manifest: manifestData)
        let runtime = ExplicitNode(node: node)
        let released = TestGate()
        let sessions = MacPluginBackendSessions(launchResolver: MacPluginLanguageServerLaunchResolver(planner: operations,
            directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state")), settings: InMemoryPluginSettings()),
            tools: runtime, versionChecker: operations, runtime: runtime, core: core, processRegistry: nil,
            credentials: MemoryPluginCredentialStore(), hostDispatcher: dispatcher, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0); released.open()
            })
        sessions.register([InstalledPluginPackage(descriptor: descriptor, installation: PluginInstallationRecord(
            pluginID: descriptor.id, activeVersion: descriptor.pluginManifest.version, origin: .localDevelopment), packageURL: package)])
        try await WorkbenchTestScope.withCleanup({
            sessions.disable(descriptor.id.rawValue)
            #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        }) { scope in
            try await scope.run("backend command and host edit", timeout: .seconds(10)) {
                sessions.runCommand("dev.lithe.fixture.workspacebackend.transform", owner: ModuleID(descriptor.id.rawValue + ".ui"), context: context.reference)
                try #require(await changed.waitUntilOpen(timeout: .seconds(5)))
                let result = try await sessions.invokePluginFunction("fixture.result", params: .object([:]), ofPlugin: descriptor.id.rawValue,
                    context: context.reference, timeout: .seconds(5), progress: { _ in })
                guard case .object(let object) = result, case .object(let value)? = object["value"] else {
                    Issue.record("Backend workflow failed: \(result)"); return
                }
                #expect(value["original"] == .string("dirty 😀"))
                #expect(document.text == "DONE 😀")
                #expect(try Data(contentsOf: package.appendingPathComponent("backend.mjs")) == script)
                #expect(try Data(contentsOf: package.appendingPathComponent("plugin.json")) == manifestData)
            }
        }
    }

    private final class ProcessSurface: EditorDocumentSurface {
        let changed: TestGate
        init(changed: TestGate) { self.changed = changed }
        func readSelections(of document: EditorDocument) async throws -> EditorSurfaceSelections {
            .init(selections: [.init(anchor: .init(line: 1, column: 1), active: .init(line: 1, column: 6))], version: document.contentVersion)
        }
        func apply(_ request: EditorSurfaceEditRequest, to document: EditorDocument) async throws -> UInt64 {
            document.text = EditorTextEditPlanner.apply(request.edits, to: document.text)
            changed.open()
            return document.contentVersion
        }
    }

    private final class ExplicitNode: BuildToolResolving, LanguageToolRuntimePort {
        let node: URL
        init(node: URL) { self.node = node }
        func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                     checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
            ResolvedBuildTool(executableURL: node, environment: ProcessInfo.processInfo.environment, executesProjectCode: false, version: nil)
        }
        func executableOnPath(_ name: String) -> URL? { name == "node" ? node : nil }
        func executableURL(at path: String) -> URL? { URL(fileURLWithPath: path) }
        func executableCandidates(_ name: String) -> [RuntimeToolCandidate] { [] }
        func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { ProcessInfo.processInfo.environment }
        func missingLanguageToolMessage(_ name: String) -> String { name }
    }
}
