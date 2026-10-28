import AppKit
import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheLanguageIntelligenceModule
import Testing
import SwiftUI
@testable import Lithe

@MainActor
struct IdeCapabilitiesTests {
    @Test(arguments: [false, true])
    func preparedProviderOutputRendersWithoutGeneratedConfigurations(dark: Bool) async throws {
        let fixture = try ProviderCapabilityExecutionFixture()
        defer { fixture.remove() }
        await fixture.run.loadProject(at: fixture.root, files: [], mavenProject: nil)
        let preparation = try JSONDecoder().decode(BuildRunPreparation.self, from: Data(
            #"{"executable":{"kind":"command","value":"fixture"},"arguments":["Main"],"workingDirectory":".","environment":{}}"#.utf8))
        let configuration = try #require(fixture.run.configurations.first { $0.id == fixture.configurationID })
        _ = try fixture.run.launchPreparedRun(preparation, workspaceURL: fixture.root, title: "Main", configuration: configuration)
        let received = TestGate()
        let observation = fixture.run.$output.sink { if $0.contains("Hello from Provider") { received.open() } }
        defer { observation.cancel() }
        fixture.process.onOutput?("Hello from Provider\nArguments: [a b]\n")
        try #require(await received.waitUntilOpen(timeout: .seconds(5)))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".lithe/run/generated.json").path))
        let suite = "provider-run-ui-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backing = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: backing)
        let container = MacServiceContainer(store: backing, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let host = NSHostingView(rootView: RunView(feature: fixture.execution.runFeature)
                .environmentObject(model).environmentObject(settings).defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "en")).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: 1100, height: 360))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 360),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let bitmap = try nativeSRGBCapture(host)
            #expect(bitmap.pixelsWide == 2200 && bitmap.pixelsHigh == 720)
            if let directory = ProcessInfo.processInfo.environment["LITHE_BUILD_CAPTURE_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("provider-run-output-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test(arguments: [Int32(0), Int32(9)])
    func agentBuildExecutionUsesProviderAndRetainsExactOperation(exitCode: Int32) async throws {
        let fixture = try ProviderCapabilityExecutionFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.root.appendingPathComponent("build.gradle"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let core = RustCoreBridge()
        let descriptor = try RustDeclarativePluginOperations(core: core).validate(manifest: Data(contentsOf:
            repository.appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-provider-execution.plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: fixture.root, buildSystems: descriptor.buildSystems)
        let provider = CapabilityBuildProviderFixture(exitCode: exitCode)
        let build = BuildSystemService(planner: RustBuildSystemOperations(core: core), tools: CapabilityBuildToolsFixture(),
            optionsStore: MacBuildOptionsStore(store: CapabilityPreferencesFixture()),
            stateLocator: CapabilityBuildStateFixture(root: fixture.root), runner: CapabilityBuildRunnerFixture(),
            providers: provider, sources: { [source] })
        defer { provider.release.open(); build.stop() }
        build.reset(workspaceURL: fixture.root)
        _ = try await build.prepareLanguageImport(workspaceURL: fixture.root)
        let entry = try #require(build.entries.first)
        let actions = CapabilityActionsFixture(root: fixture.root)
        let access = fixture.execution
        actions.execution = ExecutionFeatureAccess(mavenFeature: access.mavenFeature, runFeature: access.runFeature,
            tests: access.tests, projectDevelopment: access.projectDevelopment, buildSystems: BuildSystemsFeatureModel(service: build))
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        feature.allowExecute = true
        feature.enable()
        do {
            let inspected = await feature.call("lithe_build_inspect", arguments: [:])
            #expect((inspected["instances"] as? [[String: Any]])?.first?["instanceID"] as? String == entry.id)
            let unknown = await feature.call("lithe_build_execute", arguments: ["instanceID": entry.id, "taskID": "unknown"])
            #expect((unknown["error"] as? [String: String])?["code"] == "NOT_FOUND")
            #expect(provider.requests.isEmpty)
            let arguments: [String: Any] = ["instanceID": entry.id, "taskID": "custom", "userArguments": ["verify", "a b"]]
            let started = await feature.call("lithe_build_execute", arguments: arguments)
            let id = try #require(started["operationID"] as? String)
            try #require(await provider.started.waitUntilOpen())
            #expect(provider.requests.first?.method == "lithe/build/execute")
            guard case .object(let params) = provider.requests.first?.params else { Issue.record("Missing Provider params"); throw CapabilityBuildError() }
            #expect(params["userArguments"] == .array([.string("verify"), .string("a b")]))
            let busy = await feature.call("lithe_build_execute", arguments: arguments)
            #expect((busy["error"] as? [String: String])?["code"] == "BUSY")
            provider.progress?(BuildProviderProgress(output: "early\n"))
            let streaming = await feature.call("lithe_operation_output", arguments: ["operationID": id])
            #expect(streaming["output"] as? String == "early\n")
            let ended = TestGate()
            let observation = build.runEnded.sink { _ in ended.open() }
            defer { observation.cancel() }
            provider.release.open()
            try #require(await ended.waitUntilOpen())
            let completed = await feature.call("lithe_operation_output", arguments: ["operationID": id])
            #expect(completed["operationID"] as? String == id)
            #expect(completed["state"] as? String == (exitCode == 0 ? "completed" : "failed"))
            #expect(completed["exitCode"] as? Int32 == exitCode)
            #expect(completed["output"] as? String == "early\nfinished\n")
            provider.release = TestGate()
            provider.started = TestGate()
            let second = await feature.call("lithe_build_execute", arguments: arguments)
            let secondID = try #require(second["operationID"] as? String)
            #expect(secondID != id)
            try #require(await provider.started.waitUntilOpen())
            let expired = await feature.call("lithe_operation_stop", arguments: ["operationID": id])
            #expect((expired["error"] as? [String: String])?["code"] == "OPERATION_EXPIRED")
            #expect(build.currentRunID?.uuidString == String(secondID.dropFirst("build:".count)))
            let stopped = await feature.call("lithe_operation_stop", arguments: ["operationID": secondID])
            #expect(stopped["stopRequested"] as? Bool == true)
            #expect(build.operation?.state == .cancelled)
            #expect(build.currentRunID == nil)
            build.reset(workspaceURL: fixture.root)
            let reopened = await feature.call("lithe_operation_output", arguments: ["operationID": secondID])
            #expect((reopened["error"] as? [String: String])?["code"] == "OPERATION_EXPIRED")
        } catch { await feature.shutdown(); throw error }
        await feature.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires an explicit Maven development package and installed tool paths"))
    func agentBuildEntryRunsARealMavenModuleAndRetainsItsOutput() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let reactor = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_FIXTURE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN"]))
        let fixture = try ProviderCapabilityExecutionFixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: reactor, to: fixture.root.appendingPathComponent("nested"))
        let before = try MacNativeBuildProviderIntegrationTests.inventory(package)
        let core = RustCoreBridge()
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let released = TestGate()
        let runtime = ExplicitProviderRuntime(java: java, environment: environment)
        let directories = MacPluginStateDirectories(rootURL: fixture.root.appendingPathComponent("state"))
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations, directories: directories,
                settings: InMemoryPluginSettings()), tools: runtime, versionChecker: declarations, runtime: runtime,
            core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0)
                released.open()
            })
        let suite = "native-build-agent-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let options = MacBuildOptionsStore(store: MacUserDefaultsStore(defaults: defaults))
        let settings = fixture.root.appendingPathComponent("settings.xml")
        try Data("<settings/>".utf8).write(to: settings)
        options.setOptions(["profiles": .array([.string("ci")]), "settingsFile": .string(settings.path)],
            workspaceURL: fixture.root, buildSystemID: "maven")
        let build = BuildSystemService(planner: RustBuildSystemOperations(core: core),
            tools: CapabilityBuildToolsFixture(executable: maven), optionsStore: options,
            stateLocator: MacBuildSystemStateLocator(directories: directories, fileStorage: MacFileStorage()),
            runner: CapabilityBuildRunnerFixture(), providers: sessions, sources: { [source] })
        defer { build.stop() }
        let actions = CapabilityActionsFixture(root: fixture.root)
        let access = fixture.execution
        actions.execution = ExecutionFeatureAccess(mavenFeature: access.mavenFeature, runFeature: access.runFeature,
            tests: access.tests, projectDevelopment: access.projectDevelopment, buildSystems: BuildSystemsFeatureModel(service: build))
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        feature.allowExecute = true
        feature.enable()
        let result: Result<Void, Error>
        do {
            build.reset(workspaceURL: fixture.root)
            _ = try await build.prepareLanguageImport(workspaceURL: fixture.root)
            let entry = try #require(build.entries.first)
            let loaded = TestGate()
            let modelObservation = build.$entries.sink { entries in
                if entries.contains(where: { $0.id == entry.id && $0.modelState == .loaded }) { loaded.open() }
            }
            defer { modelObservation.cancel() }
            let reload = await feature.call("lithe_build_reload", arguments: ["instanceID": entry.id])
            #expect(reload["reloadRequested"] as? Bool == true)
            try #require(await loaded.waitUntilOpen(timeout: .seconds(60)))
            let inspect = await feature.call("lithe_build_inspect", arguments: [:])
            let projects = try #require((inspect["instances"] as? [[String: Any]])?.first?["projects"] as? [[String: String]])
            let projectID = try #require(projects.first { $0["name"] == "core" }?["id"])
            let finished = TestGate()
            let operationObservation = build.runEnded.sink { _ in finished.open() }
            defer { operationObservation.cancel() }
            let start = await feature.call("lithe_build_execute", arguments: ["instanceID": entry.id,
                "taskID": "compile", "projectID": projectID])
            let id = try #require(start["operationID"] as? String)
            try #require(await finished.waitUntilOpen(timeout: .seconds(60)))
            let output = await feature.call("lithe_operation_output", arguments: ["operationID": id])
            #expect(output["state"] as? String == "completed")
            #expect(output["exitCode"] as? Int32 == 0)
            #expect((output["output"] as? String)?.contains("BUILD SUCCESS") == true)
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(
                "nested/core/target/classes/demo/core/Greeter.class").path))
            let stop = await feature.call("lithe_operation_stop", arguments: ["operationID": id])
            #expect(stop["stopRequested"] as? Bool == true)
            #expect(build.operation?.state == .succeeded)
            result = .success(())
        } catch { result = .failure(error) }
        await feature.shutdown()
        build.stop()
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try MacNativeBuildProviderIntegrationTests.inventory(package) == before)
        try result.get()
    }

    @Test
    func revokedAndReplacedWorkspacesCannotReachProductActions() async {
        let actions = CapabilityActionsFixture()
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        let disabled = await feature.call("lithe_project_inspect", arguments: [:])
        #expect((disabled["error"] as? [String: String])?["code"] == "WORKSPACE_CLOSED")
        feature.enable()
        let inspected = await feature.call("lithe_project_inspect", arguments: [:])
        #expect(inspected["name"] as? String == "Fixture")
        actions.currentWorkspaceIdentity = WorkspaceIdentity(url: actions.root, generation: 2)
        let stale = await feature.call("lithe_environment_configure", arguments: ["javaHomePath": ""])
        #expect((stale["error"] as? [String: String])?["code"] == "WORKSPACE_CLOSED")
        #expect(actions.activationCount == 0)
        await feature.shutdown()
        #expect(actions.transport.closed)
    }

    @Test
    func sharedPermissionDenialNeverActivatesExecution() async {
        let actions = CapabilityActionsFixture()
        actions.transport.validation = ["ok": false, "error": ["code": "PERMISSION_DENIED"]]
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        feature.enable()
        let result = await feature.call("lithe_build_execute", arguments: ["instanceID": "maven@.", "taskID": "verify"])
        #expect((result["error"] as? [String: String])?["code"] == "PERMISSION_DENIED")
        #expect(actions.activationCount == 0)
        await feature.shutdown()
    }

    @Test
    func runOutputIdentitySurvivesUpdatesButChangesForReplacement() {
        let first = RunSession(id: "slot", configurationID: "service", title: "Service", output: "", isRunning: true)
        var updated = first
        updated.output = "completed"
        updated.isRunning = false
        let replacement = RunSession(id: "slot", configurationID: "service", title: "Service", output: "", isRunning: true)
        #expect(updated.executionID == first.executionID)
        #expect(replacement.executionID != first.executionID)
    }

    @Test
    func savedProviderRunKeepsItsAgentIdentityAcrossPreparationAndLaunch() async throws {
        let fixture = try ProviderCapabilityExecutionFixture()
        defer { fixture.remove() }
        await fixture.run.loadProject(at: fixture.root, files: [], mavenProject: nil)
        var preparations: [UUID] = []
        var cancelled: [UUID] = []
        let reference = fixture.reference
        let root = fixture.root
        fixture.run.configureBuildProviderRuns(start: { configuration, workspace in
            #expect(configuration.buildProvider == reference)
            #expect(workspace == root)
            let id = UUID()
            preparations.append(id)
            return id
        }, cancel: { cancelled.append($0) })
        let actions = CapabilityActionsFixture(root: fixture.root)
        actions.execution = fixture.execution
        actions.startConfiguration = { fixture.run.startConfiguration($0) }
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        feature.allowExecute = true
        feature.enable()

        do {
            // Exercise the public Agent entry points against a configuration read
            // from disk. A primary run has no module-session fallback to hide a
            // lost operation identity during the provider-to-process handoff.
            let started = await feature.call("lithe_run_start", arguments: ["configurationID": fixture.configurationID])
            let firstID = try #require(started["operationID"] as? String)
            #expect(firstID == "run:" + (try #require(preparations.first)).uuidString)
            #expect(fixture.run.isPreparingBuildRun)
            #expect(fixture.run.moduleSessions.isEmpty)
            let busy = await feature.call("lithe_run_start", arguments: ["configurationID": fixture.configurationID])
            #expect((busy["error"] as? [String: String])?["code"] == "BUSY")
            #expect(preparations.count == 1)
            let stopped = await feature.call("lithe_operation_stop", arguments: ["operationID": firstID])
            #expect(stopped["stopRequested"] as? Bool == true)
            #expect(cancelled == preparations)
            #expect(!fixture.run.isPreparingBuildRun)

            let restarted = await feature.call("lithe_run_restart", arguments: ["operationID": firstID])
            let secondID = try #require(restarted["operationID"] as? String)
            #expect(secondID != firstID)
            #expect(preparations.count == 2)
            let preparation = try JSONDecoder().decode(BuildRunPreparation.self, from: Data(
                #"{"executable":{"kind":"command","value":"fixture"},"arguments":["Main"],"workingDirectory":".","environment":{}}"#.utf8))
            let configuration = try #require(fixture.run.configurations.first { $0.id == fixture.configurationID })
            _ = try fixture.run.launchPreparedRun(preparation, workspaceURL: fixture.root, title: "Main", configuration: configuration)
            #expect(!fixture.run.isPreparingBuildRun)
            #expect(fixture.process.isRunning)
            #expect(cancelled.count == 1)
            let listed = await feature.call("lithe_operations_list", arguments: [:])
            let operation = try #require((listed["operations"] as? [[String: Any]])?.first)
            #expect(operation["operationID"] as? String == secondID)
            #expect(operation["configurationID"] as? String == fixture.configurationID)
            #expect(operation["state"] as? String == "running")

            let outputReceived = TestGate()
            let finished = TestGate()
            let outputObserver = fixture.run.$output.sink { if $0.contains("provider output") { outputReceived.open() } }
            let runningObserver = fixture.run.$isRunning.dropFirst().sink { if !$0 { finished.open() } }
            defer { outputObserver.cancel(); runningObserver.cancel() }
            fixture.process.onOutput?("provider output\n")
            #expect(await outputReceived.waitUntilOpen(timeout: .seconds(5)))
            fixture.process.complete(exitCode: 0)
            #expect(await finished.waitUntilOpen(timeout: .seconds(5)))
            let completed = await feature.call("lithe_operation_output", arguments: ["operationID": secondID])
            #expect(completed["operationID"] as? String == secondID)
            #expect(completed["state"] as? String == "completed")
            #expect(completed["exitCode"] as? Int32 == 0)
            #expect((completed["output"] as? String)?.contains("provider output") == true)

            let third = await feature.call("lithe_run_restart", arguments: ["operationID": secondID])
            let thirdID = try #require(third["operationID"] as? String)
            #expect(thirdID != secondID)
            let expired = await feature.call("lithe_operation_stop", arguments: ["operationID": secondID])
            #expect((expired["error"] as? [String: String])?["code"] == "OPERATION_EXPIRED")
            #expect(fixture.run.isPreparingBuildRun)
            #expect(cancelled.count == 1)
            _ = await feature.call("lithe_operation_stop", arguments: ["operationID": thirdID])
            #expect(cancelled.map { "run:" + $0.uuidString } == [firstID, thirdID])
        } catch {
            await feature.shutdown()
            throw error
        }
        await feature.shutdown()
        #expect(actions.transport.closed)
    }
}

@MainActor
private final class CapabilityTransportFixture: IdeHostTransport {
    var validation: [String: Any] = ["ok": true]
    var closed = false
    func open(workspace: URL, permissions: [String: Bool]) throws -> [String: Any] {
        ["hostID": "fixture-host", "configuration": ["mcpServers": [String: String]()]]
    }
    func control(_ action: String, arguments: [String: Any]) throws -> [String: Any] {
        if action == "validate" { return validation }
        if action == "close" { closed = true }
        if action == "output" { return arguments["snapshot"] as? [String: Any] ?? [:] }
        return ["requests": []]
    }
}

@MainActor
private final class CapabilityActionsFixture: IdeCapabilityActions {
    let id = UUID()
    let projectName = "Fixture"
    let root: URL
    let transport = CapabilityTransportFixture()
    var activationCount = 0
    var execution: ExecutionFeatureAccess?
    var startConfiguration: ((RunConfiguration) -> Void)?
    var currentWorkspaceIdentity: WorkspaceIdentity?
    var runtimeFeature: RuntimeSettingsFeatureModel { preconditionFailure("Authorization tests must not inspect runtimes") }
    var ideHostTransport: (any IdeHostTransport)? { transport }
    init(root: URL = URL(fileURLWithPath: "/fixture/project")) {
        self.root = root
        currentWorkspaceIdentity = WorkspaceIdentity(url: root, generation: 1)
    }
    func isCurrentWorkspace(_ identity: WorkspaceIdentity) -> Bool { identity == currentWorkspaceIdentity }
    func activateExecutionModule() async -> ExecutionFeatureAccess? { activationCount += 1; return execution }
    func ensureRunProjectReady(_ run: RunFeatureModel, for identity: WorkspaceIdentity) async -> RunProjectReadiness { .stale }
    func prepareProjectRuntimeSettings() async {}
    func persistProjectRuntimeSettings() {}
    func reloadMavenProject(rescan: Bool) async {}
    func startAPIConfiguration(_ configuration: RunConfiguration) async { startConfiguration?(configuration) }
    func registerIdeCapabilities(_ feature: IdeCapabilitiesFeatureModel) {}
    func unregisterIdeCapabilities() {}
    func copyIdeConfiguration(_ text: String) {}
}

@MainActor
private final class ProviderCapabilityExecutionFixture {
    let root: URL
    let reference = BuildProviderRunReference(pluginID: "dev.example", buildSystemID: "fixture", root: ".",
        run: "application", projectID: "project", targetID: "main", userArguments: [])
    let configurationID: String
    let process = CapabilityProcessFixture()
    let run: RunService
    let execution: ExecutionFeatureAccess

    init() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-agent-" + UUID().uuidString, isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let preferences = CapabilityPreferencesFixture()
            let store = MacRunConfigurationStore(core: core, storage: MacFileStorage(), preferences: preferences)
            configurationID = try store.saveBuildProviderConfiguration(reference, name: "Main", at: root)
            let runtime = CapabilityRuntimeFixture()
            let resolver = CapabilityExecutableFixture()
            run = RunService(runtime: runtime, process: process, processFactory: { CapabilityProcessFixture() },
                fileAccess: MacRunFileAccess(storage: MacFileStorage()), preferences: preferences,
                serverPortParser: CapabilityPortParserFixture(), runConfigurationOperations: store,
                executableResolver: resolver, languageProviderCatalog: .compatibilityFallback,
                languageRunProviders: .standard(catalog: .compatibilityFallback))
            let maven = MavenFeatureModel(service: MavenService(runtimeService: runtime, mavenOperations: RustJavaMavenOperations(core: core)))
            let runFeature = RunFeatureModel(service: run)
            execution = ExecutionFeatureAccess(mavenFeature: maven, runFeature: runFeature,
                tests: LanguageTestService(executableResolver: resolver, processFactory: { CapabilityProcessFixture() }),
                projectDevelopment: ProjectDevelopmentFeatureModel(mavenFeature: maven, runFeature: runFeature), buildSystems: nil)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() {
        run.reset()
        execution.mavenFeature.reset()
        execution.tests.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CapabilityProcessFixture: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    func start(_ request: ProcessRequest) throws { isRunning = true }
    func send(_ input: Data) throws {}
    func stop() { isRunning = false }
    func complete(exitCode: Int32) { isRunning = false; onTermination?(exitCode) }
}

@MainActor
private final class CapabilityRuntimeFixture: RunRuntimePort, MavenRuntimePort {
    func mavenExecutable(for project: MavenProject, overridePath: String?) -> URL? { nil }
    func mavenProcessEnvironment(javaHomePath: String?) -> [String: String] { [:] }
    func setActiveServiceJavaHomePath(_ path: String) {}
    func javaHomeURL(overridePath: String?) -> URL? { nil }
    func mavenJavaHomeURL(overridePath: String?) -> URL? { nil }
    func runConfigurationToolchainCandidates(for project: MavenProject?, projectRoot: URL?,
        javaHomeOverride: String?, mavenExecutableOverride: String?) -> [ProjectToolchainCandidate] { [] }
    func loadRunConfigurationToolchainCandidates(for project: MavenProject?, projectRoot: URL?,
        javaHomeOverride: String?, mavenExecutableOverride: String?) async throws -> [ProjectToolchainCandidate] { [] }
}

@MainActor
private final class CapabilityExecutableFixture: RunExecutableResolving {
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable {
        ResolvedRunExecutable(executableURL: URL(fileURLWithPath: "/fixture/launcher"), environment: [:])
    }
}

private final class CapabilityPreferencesFixture: KeyValueStore, RunPreferenceStore, @unchecked Sendable {
    nonisolated func data(forKey key: String) -> Data? { nil }
    nonisolated func object(forKey key: String) -> Any? { nil }
    nonisolated func string(forKey key: String) -> String? { nil }
    nonisolated func stringArray(forKey key: String) -> [String]? { nil }
    nonisolated func set(_ value: Any?, forKey key: String) {}
    nonisolated func setData(_ data: Data, forKey key: String) {}
    nonisolated func setString(_ value: String, forKey key: String) {}
}

private struct CapabilityPortParserFixture: RunServerPortParsing {
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
}

private struct CapabilityBuildError: Error {}

@MainActor
private final class CapabilityBuildProviderFixture: BuildProviderRequesting {
    var started = TestGate()
    var release = TestGate()
    let exitCode: Int32
    var requests: [BuildProviderRequest] = []
    var progress: (@MainActor @Sendable (BuildProviderProgress) -> Void)?
    init(exitCode: Int32) { self.exitCode = exitCode }
    func send(_ request: BuildProviderRequest, to target: BuildProviderTarget, timeout: Duration) async throws -> ToolingJSONValue {
        throw CapabilityBuildError()
    }
    func prepareRun(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                    progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> ToolingJSONValue {
        throw CapabilityBuildError()
    }
    func execute(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                 progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> BuildProviderExecutionResult {
        requests.append(request)
        self.progress = progress
        started.open()
        guard await release.waitUntilOpen() else { throw CancellationError() }
        try Task.checkCancellation()
        return BuildProviderExecutionResult(exitCode: exitCode, output: "early\nfinished\n")
    }
    func retainProviders(_ keep: (BuildProviderTarget) -> Bool) {}
}

@MainActor
private final class CapabilityBuildToolsFixture: BuildToolResolving {
    let executable: URL
    init(executable: URL = URL(fileURLWithPath: "/fixture/tool")) { self.executable = executable }
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: executable, environment: [:], executesProjectCode: false, version: nil)
    }
}

private struct CapabilityBuildStateFixture: BuildSystemStateLocating {
    let root: URL
    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL { root }
    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL { root.appendingPathComponent(UUID().uuidString) }
    func removeOutputFile(_ url: URL) {}
}

private struct CapabilityBuildRunnerFixture: BuildCommandRunning {
    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> BuildCommandResult {
        throw CapabilityBuildError()
    }
}
