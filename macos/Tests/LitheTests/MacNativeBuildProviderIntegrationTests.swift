import CryptoKit
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

/// Explicit tool integration: the production macOS session table, linked Core,
/// real Java SDK backend and Maven reactor. No page or scripted runtime Core.
@Suite("Native macOS build Provider integration", .serialized)
@MainActor
struct MacNativeBuildProviderIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D native-configuration development package"))
    func nativeSettingsStayIndependentAcrossReactorRoots() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-reactor-settings-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        for root in ["a", "b"] {
            let directory = workspace.appendingPathComponent(root)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("<broken>".utf8).write(to: directory.appendingPathComponent("pom.xml"))
        }
        let a = scratch.appendingPathComponent("a settings.xml")
        let b = scratch.appendingPathComponent("b settings.xml")
        let replacement = scratch.appendingPathComponent("replacement.xml")
        for (url, name) in [(a, "a"), (b, "b"), (replacement, "replacement")] {
            try Data("<settings><localRepository>\(scratch.appendingPathComponent(name + "-repository").path)</localRepository></settings>".utf8).write(to: url)
        }
        let originalB = try Data(contentsOf: b)
        let before = try Self.inventory(package)
        let core = RustCoreBridge()
        let planner = RustBuildSystemOperations(core: core)
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let runtime = ExplicitProviderRuntime(java: java, environment: environment)
        let released = TestGate()
        let directories = MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state"))
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations, directories: directories,
                settings: InMemoryPluginSettings()), tools: runtime, versionChecker: declarations,
            runtime: runtime, core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0); released.open()
            })
        let domain = "lithe.native-reactor-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let options = MacBuildOptionsStore(store: MacUserDefaultsStore(defaults: defaults))
        options.setInstanceOptions(["a": ["settingsFile": .string(a.path)], "b": ["settingsFile": .string(b.path)]],
            workspaceURL: workspace, buildSystemID: "maven")
        let storage = MacFileStorage()
        let build = BuildSystemService(planner: planner, tools: ExplicitNativeConfigurationTool(maven: maven), optionsStore: options,
            stateLocator: MacBuildSystemStateLocator(directories: directories, fileStorage: storage),
            runner: MacBuildCommandRunner(), providers: sessions,
            nativeConfigurationFiles: MacBuildNativeConfigurationStore(storage: storage, planner: planner,
                immutableRoots: [package, Bundle.main.bundleURL]), sources: { [source] })
        let outcome: Result<Void, Error>
        do {
            build.reset(workspaceURL: workspace)
            _ = try await build.prepareLanguageImport(workspaceURL: workspace)
            #expect(build.entries.map(\.id) == ["maven:a", "maven:b"])
            let firstA = try await build.readNativeConfiguration("maven:a")
            let firstB = try await build.readNativeConfiguration("maven:b")
            let userA = try #require(firstA.sources.first { $0.id == "user" })
            let userB = try #require(firstB.sources.first { $0.id == "user" })
            #expect(userA.uri == a.absoluteString)
            #expect(userB.uri == b.absoluteString)
            let savedPath = scratch.appendingPathComponent("saved-a-repository").path
            _ = try await build.saveNativeConfiguration("maven:a", snapshot: firstA,
                edits: BuildNativeConfigurationEdits(sourceID: userA.id, revision: userA.revision,
                    values: ["localRepository": .string(savedPath)]))
            let freshB = try await build.readNativeConfiguration("maven:b")
            #expect(freshB.sources.first { $0.id == "user" } == userB)
            #expect(try Data(contentsOf: b) == originalB)
            _ = try build.configureOption("maven:a", optionID: "settingsFile", value: .string(replacement.path))
            _ = try await build.prepareLanguageImport(workspaceURL: workspace)
            let changedA = try await build.readNativeConfiguration("maven:a")
            let unchangedB = try await build.readNativeConfiguration("maven:b")
            #expect(changedA.sources.first { $0.id == "user" }?.uri == replacement.absoluteString)
            #expect(unchangedB.sources.first { $0.id == "user" } == userB)
            #expect(options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven")["b"]?["settingsFile"] == .string(b.path))
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent("a/target").path))
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent("b/target").path))
            outcome = .success(())
        } catch { outcome = .failure(error) }
        build.stop(); sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D native-configuration development package"))
    func nativeSettingsUseProductionStorageReadBackAndRejectExternalChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-settings-workflow-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        try files.createDirectory(at: workspace.appendingPathComponent(".mvn"), withIntermediateDirectories: true)
        try Data("<broken>".utf8).write(to: workspace.appendingPathComponent("pom.xml"))
        let user = scratch.appendingPathComponent("user settings.xml")
        let global = scratch.appendingPathComponent("global.xml")
        let inheritedRepository = scratch.appendingPathComponent("inherited-repository").path
        let selectedRepository = scratch.appendingPathComponent("saved-repository").path
        let original = "<settings><!--keep--><servers><server><password>test-secret-preserved</password></server></servers><activeProfiles><activeProfile>ci</activeProfile></activeProfiles></settings>"
        try Data(original.utf8).write(to: user)
        try Data("<settings><localRepository>\(inheritedRepository)</localRepository></settings>".utf8).write(to: global)
        try Data("--global-settings=\(global.path)\n".utf8).write(to: workspace.appendingPathComponent(".mvn/maven.config"))
        let before = try Self.inventory(package)
        let core = RustCoreBridge()
        let planner = RustBuildSystemOperations(core: core)
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let selectedRuntime = ExplicitProviderRuntime(java: java, environment: environment)
        let released = TestGate()
        let directories = MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state"))
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations, directories: directories,
                settings: InMemoryPluginSettings()), tools: selectedRuntime, versionChecker: declarations,
            runtime: selectedRuntime, core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0); released.open()
            })
        let preferenceDomain = "lithe.native-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: preferenceDomain))
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let options = MacBuildOptionsStore(store: MacUserDefaultsStore(defaults: defaults))
        options.setOptions(["settingsFile": .string(user.path)], workspaceURL: workspace, buildSystemID: "maven")
        let storage = MacFileStorage()
        func service() -> BuildSystemService {
            BuildSystemService(planner: planner, tools: ExplicitNativeConfigurationTool(maven: maven), optionsStore: options,
                stateLocator: MacBuildSystemStateLocator(directories: directories, fileStorage: storage),
                runner: MacBuildCommandRunner(), providers: sessions,
                nativeConfigurationFiles: MacBuildNativeConfigurationStore(storage: storage, planner: planner,
                    immutableRoots: [package, Bundle.main.bundleURL]), sources: { [source] })
        }
        let build = service()
        var reopened: BuildSystemService?
        let outcome: Result<Void, Error>
        do {
            build.reset(workspaceURL: workspace)
            _ = try await build.prepareLanguageImport(workspaceURL: workspace)
            let entry = try #require(build.entries.first)
            let first = try await build.readNativeConfiguration(entry.id)
            let userSource = try #require(first.sources.first { $0.id == "user" })
            let repository = try #require(userSource.fields.first { $0.id == "localRepository" })
            #expect(repository.value == .null)
            #expect(repository.effectiveValue == .string(inheritedRepository))
            #expect(try String(contentsOf: user, encoding: .utf8) == original)
            var draft = BuildNativeConfigurationDraft(source: userSource)
            #expect(!draft.isDirty)
            draft.setOverride(true, fieldID: repository.id)
            draft.setValue(.string(selectedRepository), fieldID: repository.id)
            let saved = try await build.saveNativeConfiguration(entry.id, snapshot: first, edits: draft.edits)
            #expect(saved.sources.first { $0.id == "user" }?.fields.first { $0.id == "localRepository" }?.effectiveValue == .string(selectedRepository))
            let savedText = try String(contentsOf: user, encoding: .utf8)
            #expect(savedText.contains("<!--keep-->"))
            #expect(savedText.contains("<password>test-secret-preserved</password>"))
            #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("test-secret-preserved"))
            let current = try #require(saved.sources.first { $0.id == "user" })
            let external = savedText + "\n<!-- external save -->"
            try Data(external.utf8).write(to: user)
            await #expect(throws: (any Error).self) {
                try await build.saveNativeConfiguration(entry.id, snapshot: saved, edits: BuildNativeConfigurationEdits(
                    sourceID: current.id, revision: current.revision, values: ["localRepository": .string("/obsolete")]))
            }
            #expect(try String(contentsOf: user, encoding: .utf8) == external)
            build.stop()
            let next = service(); reopened = next
            next.reset(workspaceURL: workspace)
            _ = try await next.prepareLanguageImport(workspaceURL: workspace)
            let nextEntry = try #require(next.entries.first)
            let fresh = try await next.readNativeConfiguration(nextEntry.id)
            #expect(fresh.sources.first { $0.id == "user" }?.fields.first { $0.id == "localRepository" }?.value == .string(selectedRepository))
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent("target").path))
            outcome = .success(())
        } catch { outcome = .failure(error) }
        build.stop(); reopened?.stop(); sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

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
@MainActor
private final class ExplicitNativeConfigurationTool: BuildToolResolving {
    let maven: URL
    init(maven: URL) { self.maven = maven }
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: maven, environment: [:], executesProjectCode: false, version: nil)
    }
}
@MainActor private final class NativeProviderProgress { var output = "" }

/// Explicit test-selected executable paths. All process/RPC execution is real;
/// this port avoids reading or modifying the user's runtime preferences.
@MainActor
final class ExplicitProviderRuntime: BuildToolResolving, LanguageToolRuntimePort {
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
