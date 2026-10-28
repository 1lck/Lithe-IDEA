import CryptoKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

/// Explicit tool integration: the production macOS session table, linked Core,
/// real Java SDK backend and Maven reactor. No page or scripted runtime Core.
@Suite("Native macOS build Provider integration", .serialized)
@MainActor
struct MacNativeBuildProviderIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_C_MAVEN_PACKAGE"] != nil,
                   "Requires an explicit development Maven package and tool paths"))
    func realMavenProviderBuildsAndTestsWithoutAPluginPage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN_PACKAGE"]))
        let fixture = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN_FIXTURE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        try #require(RustCoreBridge().isAvailable)
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-provider-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        try files.copyItem(at: fixture, to: workspace.appendingPathComponent("nested"))
        let before = try Self.inventory(package)
        let core = RustCoreBridge()
        let operations = RustBuildSystemOperations(core: core)
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let target = BuildSystemTarget(manifest: descriptor.normalizedManifest, buildSystemID: "maven")
        let provider = BuildProviderTarget(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystemID: "maven", workspaceURL: workspace)
        let released = TestGate()
        let selectedTools = ExplicitProviderRuntime(java: java, environment: environment)
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations,
                directories: MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state")), settings: InMemoryPluginSettings()),
            tools: selectedTools, versionChecker: declarations, runtime: selectedTools, core: core, processRegistry: nil,
            endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0)
                released.open()
            })
        let context = BuildPlanContext(root: "nested", options: ["profiles": .array([.string("ci")])],
            pluginDirectory: package, workspaceStateDirectory: scratch.appendingPathComponent("workspace-state"))
        let outcome: Result<Void, Error>
        do {
            let plan = try operations.modelPlan(target, context: context, outputFile: nil,
                providerHints: BuildProviderHints(toolExecutable: maven))
            guard case .provider(let request) = plan else { throw NativeProviderIntegrationError.unexpectedCommand }
            let raw = try await sessions.send(request, to: provider, timeout: .seconds(20))
            let model = try operations.decodeModel(target, workspaceURL: workspace, root: context.root,
                output: .providerResult(raw), options: context.options)
            #expect(Set(model.projects.map(\.name)) == ["reactor", "core", "app"])
            let project = try #require(model.projects.first { $0.name == "core" })
            let taskPlan = try operations.taskPlan(target, context: context,
                request: BuildTaskRequest(task: "compile", project: BuildSelection(project: project)))
            guard case .provider(let build) = taskPlan else { throw NativeProviderIntegrationError.unexpectedCommand }
            let progress = NativeProviderProgress()
            let built = try await sessions.execute(Self.withTool(build, maven: maven), on: provider, timeout: .seconds(20)) {
                progress.output += $0.output ?? ""
            }
            #expect(built.exitCode == 0)
            #expect(built.output == progress.output)
            #expect(files.fileExists(atPath: workspace.appendingPathComponent("nested/core/target/classes/demo/core/Greeter.class").path))
            let testPlan = try operations.testPlan(target, context: context,
                request: BuildTestRequest(project: BuildSelection(project: project), suite: "demo.core.GreeterTest", testCase: "greetsByName"))
            guard case .provider(let test) = testPlan.execution else { throw NativeProviderIntegrationError.unexpectedCommand }
            let tested = try await sessions.execute(Self.withTool(test, maven: maven), on: provider, timeout: .seconds(20)) { _ in }
            #expect(tested.exitCode == 0)
            let results = try operations.decodeTestResults(target, request: BuildTestResultsRequest(workspaceURL: workspace,
                root: context.root, project: project.path, projects: model.projects.map(\.path), output: tested.output,
                notBefore: nil, suite: "demo.core.GreeterTest"))
            #expect(results.summary.total == 1)
            #expect(results.summary.failed == 0)
            #expect(results.tests.first?.name == "greetsByName")
            #expect(try await sessions.pluginFunctions(of: provider).isEmpty)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        // Shutdown is observed through the production session's release callback,
        // including after failed assertions/requests; the scratch workspace outlives it.
        sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

    private static func withTool(_ request: BuildProviderRequest, maven: URL) -> BuildProviderRequest {
        guard case .object(var params) = request.params else { return request }
        params["tool"] = .object(["executable": .string(maven.path)])
        return BuildProviderRequest(method: request.method, params: .object(params), optionFingerprint: request.optionFingerprint,
            executesProjectCode: request.executesProjectCode, mayUseNetwork: request.mayUseNetwork)
    }

    static func inventory(_ root: URL) throws -> [String: String] {
        let files = FileManager.default
        let paths = try files.subpathsOfDirectory(atPath: root.path).sorted()
        return try Dictionary(uniqueKeysWithValues: paths.map { relative in
            let path = root.appendingPathComponent(relative)
            let attributes = try files.attributesOfItem(atPath: path.path)
            let type = attributes[.type] as? FileAttributeType
            let digest = type == .typeRegular ? SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined() : "directory"
            return (relative, "\(attributes[.posixPermissions] ?? ""):\(digest)")
        })
    }
}

private enum NativeProviderIntegrationError: Error { case unexpectedCommand }
@MainActor private final class NativeProviderProgress { var output = "" }

/// Explicit test-selected executable paths. All process/RPC execution is real;
/// this port avoids reading or modifying the user's runtime preferences.
@MainActor
private final class ExplicitProviderRuntime: BuildToolResolving, LanguageToolRuntimePort {
    let java: URL
    let environment: [String: String]
    init(java: URL, environment: [String: String]) {
        self.java = java
        var values = environment
        values["JAVA_HOME"] = java.deletingLastPathComponent().deletingLastPathComponent().path
        self.environment = values
    }
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: java, environment: environment, executesProjectCode: false, version: nil)
    }
    func executableOnPath(_ name: String) -> URL? { name == "java" ? java : nil }
    func executableURL(at path: String) -> URL? { path == java.path ? java : nil }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { environment }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}
