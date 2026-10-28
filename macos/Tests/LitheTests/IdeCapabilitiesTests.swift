import AppKit
import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule
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
        let result = await feature.call("lithe_maven_execute", arguments: ["goals": ["verify"]])
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
            let maven = MavenFeatureModel(service: MavenService(runtimeService: runtime, process: CapabilityProcessFixture(),
                dependencyProcess: CapabilityProcessFixture(), mavenOperations: RustJavaMavenOperations(core: core)))
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
