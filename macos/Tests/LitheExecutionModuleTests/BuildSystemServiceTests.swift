import Combine
import Foundation
@testable import LitheExecutionModule
import LitheCoreContracts
import Testing

@MainActor
struct BuildSystemServiceTests {
    private static let workspace = URL(fileURLWithPath: "/workspace/demo")

    @Test
    func detectionPublishesEntriesAndNamesRefusedPlugins() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = try decode(BuildDetection.self, """
        {"instances": [\(Self.instanceJSON(modelSource: "static", model: #"{"projects": [{"id": "p", "path": ".", "name": "demo"}]}"#))],
         "rejected": [{"index": 1, "error": {"code": "plugin.build.invalid", "message": "Broken manifest."}}],
         "shadowed": [{"pluginID": "dev.other", "buildSystemID": "fixture", "by": "dev.example"}]}
        """)
        let harness = Harness(planner: planner, sources: [fixtureSource(), fixtureSource(pluginID: "dev.broken")])
        defer { harness.service.stop() }

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        let entry = try #require(harness.service.entries.first)
        #expect(entry.model?.projects.map(\.name) == ["demo"])
        #expect(entry.modelState == .loaded)
        #expect(entry.options.map(\.id) == ["release"])
        #expect(entry.sync?.watch == ["build.file"])
        #expect(harness.service.issues.contains("dev.broken: Broken manifest."))
        #expect(harness.service.issues.count == 2)
        #expect(!harness.service.isDetecting)
    }

    @Test
    func commandModelRunsWithCapturedStandardOutputAndRemovesItsOutputFile() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: ["warming up\n"], result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL"))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })

        let request = try #require(runner.requests.first)
        #expect(request.capturesStandardOutput)
        #expect(request.arguments == ["model"])
        #expect(request.workingDirectory.path == "/workspace/demo/app")
        #expect(request.environment == ["PATH": "/tool/bin", "FROM_PLAN": "1"])
        #expect(request.timeout == BuildSystemService.modelTimeout)
        #expect(planner.decodedModelOutputs == [.stdout("MODEL")])
        #expect(harness.service.entries.first?.model?.projects.map(\.name) == ["loaded"])
        #expect(harness.stateLocator.removed == harness.stateLocator.allocated)
        #expect(harness.service.output.contains("warming up"))
        #expect(!harness.service.hasActiveWork)
    }

    @Test
    func failedModelCommandReportsItsExitCode() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: ["no such task\n"], result: BuildCommandResult(termination: .exited(2)))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries {
            if case .failed = $0.first?.modelState { return true }
            return false
        })
        guard case .failed(let message)? = harness.service.entries.first?.modelState else { return }
        #expect(message.contains("2"))
        #expect(message.contains("no such task"))
        #expect(planner.decodedModelOutputs.isEmpty)
    }

    @Test
    func taskStreamsOutputInOrderAndDecodesDiagnostics() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        planner.diagnostics = try decode([BuildDiagnostic].self, """
        [{"path": "src/a.rs", "line": 3, "severity": "error", "message": "bad"}]
        """)
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: ["one\n", "two\n", "three\n"], result: BuildCommandResult(termination: .exited(1)))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(harness.service.runState == .running)
        #expect(await harness.waitForRunState { $0 != .running })

        guard case .failed = harness.service.runState else {
            Issue.record("Expected a failed run, got \(harness.service.runState)")
            return
        }
        #expect(harness.service.output == "$ /tool/bin/fake build 'with space'\none\ntwo\nthree\n")
        #expect(harness.service.diagnostics.map(\.path) == ["src/a.rs"])
        #expect(planner.diagnosticOutputs == ["one\ntwo\nthree\n"])
        #expect(runner.requests.first?.capturesStandardOutput == false)
        #expect(runner.requests.first?.timeout == nil)
    }

    @Test
    func stopRunCancelsTheRunningCommand() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let runner = FakeBuildRunner()
        runner.blocksUntilCancelled = true
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await runner.started.waitUntilOpen())
        #expect(harness.service.hasActiveWork)

        harness.service.stopRun()
        #expect(harness.service.runState == .cancelled)
        #expect(await runner.cancelled.waitUntilOpen())
        #expect(!harness.service.hasActiveWork)
    }

    @Test
    func disablingAPluginStopsItsRunAndRemovesItsInstances() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let runner = FakeBuildRunner()
        runner.blocksUntilCancelled = true
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await runner.started.waitUntilOpen())

        harness.sources = []
        harness.service.pluginsChanged()

        #expect(harness.service.runState == .cancelled)
        #expect(await runner.cancelled.waitUntilOpen())
        #expect(harness.service.entries.isEmpty)
        #expect(!harness.service.hasBuildSystemPlugins)
    }

    @Test
    func refusedOptionValuesAreReplacedByTheirEffectiveValue() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        planner.optionsResolution = try decode(BuildOptionsResolution.self, """
        {"options": [{"id": "features", "displayName": "Features", "kind": "multiSelect",
                      "value": ["fast"], "source": "user"}],
         "dropped": ["features", "removed"], "fingerprint": "f"}
        """)
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["removed": .bool(true)]
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.setOption(Self.instanceID, optionID: "features", value: .array([.string("fast"), .string("gone")]))

        #expect(harness.optionsStore.values["fixture"] == ["features": .array([.string("fast")])])
        #expect(harness.service.entries.first?.options.first?.value == .array([.string("fast")]))
    }

    @Test
    func changedFingerprintMarksALoadedCommandModelStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: [], result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL"))
        planner.modelOutput = .stdout
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.service.entries.first?.isReloadRequired == false)

        planner.fingerprint = "changed"
        harness.service.detect()
        #expect(await harness.waitForEntries { $0.first?.isReloadRequired == true })
        #expect(harness.service.entries.first?.model?.projects.map(\.name) == ["loaded"])
    }

    // MARK: Fixtures

    private static let instanceID = "fixture:app"

    private static func instanceJSON(modelSource: String, model: String? = nil) -> String {
        """
        {"id": "\(instanceID)", "pluginID": "dev.example", "buildSystemID": "fixture",
         "displayName": "Fixture", "root": "app", "modelSource": "\(modelSource)",
         "optionFingerprint": "o"\(model.map { ", \"model\": \($0)" } ?? "")}
        """
    }

    private static func instance(modelSource: String) throws -> BuildSystemInstance {
        try decode(BuildSystemInstance.self, instanceJSON(modelSource: modelSource))
    }
}

private func fixtureSource(pluginID: String = "dev.example") -> BuildSystemPluginSource {
    BuildSystemPluginSource(
        pluginID: pluginID,
        manifest: Data("{}".utf8),
        packageURL: URL(fileURLWithPath: "/plugins/\(pluginID)"),
        buildSystems: [DeclarativeBuildSystem(
            id: "fixture", displayName: "Fixture", modelSource: .command, tasks: [],
            testScopes: [], dependencyScopes: []
        )]
    )
}

private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@MainActor
private final class Harness {
    let service: BuildSystemService
    let optionsStore = FakeOptionsStore()
    let stateLocator = FakeStateLocator()
    private let enabledSources: SourceList

    /// The plugins the service sees as enabled.
    var sources: [BuildSystemPluginSource] {
        get { enabledSources.value }
        set { enabledSources.value = newValue }
    }

    init(
        planner: FakeBuildPlanner,
        runner: FakeBuildRunner = FakeBuildRunner(),
        sources: [BuildSystemPluginSource] = [fixtureSource()]
    ) {
        let enabledSources = SourceList(sources)
        self.enabledSources = enabledSources
        service = BuildSystemService(
            planner: planner,
            tools: FakeToolResolver(),
            optionsStore: optionsStore,
            stateLocator: stateLocator,
            runner: runner,
            sources: { enabledSources.value }
        )
    }

    func waitForEntries(_ predicate: @escaping ([BuildSystemEntry]) -> Bool) async -> Bool {
        await wait(for: service.$entries, predicate)
    }

    func waitForRunState(_ predicate: @escaping (BuildRunState) -> Bool) async -> Bool {
        await wait(for: service.$runState, predicate)
    }

    /// `@Published` reports in `willSet`; the waiter resumes in a later main
    /// actor job, after the value is stored.
    private func wait<Value>(
        for publisher: Published<Value>.Publisher,
        _ predicate: @escaping (Value) -> Bool
    ) async -> Bool {
        let gate = BuildTestGate()
        let observation = publisher.sink { if predicate($0) { gate.open() } }
        defer { observation.cancel() }
        return await gate.waitUntilOpen()
    }
}

@MainActor
private final class SourceList {
    var value: [BuildSystemPluginSource]
    init(_ value: [BuildSystemPluginSource]) { self.value = value }
}

/// Opens once. Waiters give up at a local deadline, so a failed test does
/// not hang until the CI timeout; modelled on `LitheTests/TestGate`.
private final class BuildTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]

    func open() {
        let (resumed, cancelled) = lock.withLock {
            isOpen = true
            defer { waiters.removeAll(); deadlines.removeAll() }
            return (Array(waiters.values), Array(deadlines.values))
        }
        cancelled.forEach { $0.cancel() }
        resumed.forEach { $0.resume(returning: true) }
    }

    func waitUntilOpen(timeout: Duration = .seconds(5)) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let openAlready = lock.withLock {
                    if !isOpen { waiters[id] = continuation }
                    return isOpen
                }
                if openAlready {
                    continuation.resume(returning: true)
                    return
                }
                let deadline = Task { [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: the gate deadline bounds a failed asynchronous test while successful signaling remains continuation-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(id, result: false)
                }
                let registered = lock.withLock {
                    guard waiters[id] != nil else { return false }
                    deadlines[id] = deadline
                    return true
                }
                if !registered { deadline.cancel() }
                if Task.isCancelled { finish(id, result: false) }
            }
        } onCancel: {
            finish(id, result: false)
        }
    }

    private func finish(_ id: UUID, result: Bool) {
        let (waiter, deadline) = lock.withLock {
            (waiters.removeValue(forKey: id), deadlines.removeValue(forKey: id))
        }
        deadline?.cancel()
        waiter?.resume(returning: result)
    }
}

private final class FakeBuildPlanner: BuildSystemPlanning, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var detection = BuildDetection(instances: [])
        var modelOutput: BuildProcessPlan.Output = .outputFile
        var diagnostics: [BuildDiagnostic] = []
        var optionsResolution: BuildOptionsResolution?
        var fingerprint = "initial"
        var decodedModelOutputs: [BuildCommandOutput] = []
        var diagnosticOutputs: [String] = []
    }

    private func access<Value>(_ body: (inout State) -> Value) -> Value { lock.withLock { body(&state) } }

    var detection: BuildDetection {
        get { access { $0.detection } }
        set { access { $0.detection = newValue } }
    }
    var modelOutput: BuildProcessPlan.Output {
        get { access { $0.modelOutput } }
        set { access { $0.modelOutput = newValue } }
    }
    var diagnostics: [BuildDiagnostic] {
        get { access { $0.diagnostics } }
        set { access { $0.diagnostics = newValue } }
    }
    var optionsResolution: BuildOptionsResolution? {
        get { access { $0.optionsResolution } }
        set { access { $0.optionsResolution = newValue } }
    }
    var fingerprint: String {
        get { access { $0.fingerprint } }
        set { access { $0.fingerprint = newValue } }
    }
    var decodedModelOutputs: [BuildCommandOutput] { access { $0.decodedModelOutputs } }
    var diagnosticOutputs: [String] { access { $0.diagnosticOutputs } }

    func detect(
        workspaceURL: URL,
        sources: [BuildSystemPluginSource],
        options: [String: [String: ToolingJSONValue]]
    ) throws -> BuildDetection { detection }

    func invocationPlan(_ target: BuildSystemTarget, root: String) throws -> BuildInvocation {
        BuildInvocation(executables: [.command("fake")])
    }

    func checkToolVersion(_ target: BuildSystemTarget, runtime: String?, output: String) throws -> BuildVersionCheck {
        BuildVersionCheck(satisfied: true, version: nil)
    }

    func resolveOptions(
        _ target: BuildSystemTarget,
        options: [String: ToolingJSONValue],
        modelValues: [String: [String]]?
    ) throws -> BuildOptionsResolution {
        if let resolution = optionsResolution { return resolution }
        return try decode(BuildOptionsResolution.self, """
        {"options": [{"id": "release", "displayName": "Release", "kind": "boolean", "value": false}],
         "dropped": [], "fingerprint": "f"}
        """)
    }

    func modelPlan(_ target: BuildSystemTarget, context: BuildPlanContext, outputFile: URL?) throws -> BuildOutputPlan {
        .process(plan(["model"], output: modelOutput))
    }

    func taskPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTaskRequest) throws
        -> BuildProcessPlan {
        plan([request.task, "with space"], output: nil)
    }

    func testPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTestRequest) throws
        -> BuildTestPlan {
        BuildTestPlan(process: plan(["test"], output: nil), results: nil)
    }

    func dependencyPlan(
        _ target: BuildSystemTarget,
        context: BuildPlanContext,
        project: BuildSelection?,
        outputFile: URL?
    ) throws -> BuildOutputPlan {
        .process(plan(["dependencies"], output: .stdout))
    }

    func decodeModel(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        output: BuildCommandOutput,
        options: [String: ToolingJSONValue]
    ) throws -> BuildModel {
        access { $0.decodedModelOutputs.append(output) }
        return BuildModel(projects: [BuildModel.Project(id: "loaded", path: "app", name: "loaded")])
    }

    func decodeTestResults(_ target: BuildSystemTarget, request: BuildTestResultsRequest) throws -> BuildTestResults {
        throw DeclarativePluginRejection(code: "plugin.build.unavailable", message: "No results.", field: nil)
    }

    func decodeDiagnostics(_ target: BuildSystemTarget, workspaceURL: URL, root: String, output: String) throws
        -> [BuildDiagnostic] {
        access {
            $0.diagnosticOutputs.append(output)
            return $0.diagnostics
        }
    }

    func decodeDependencies(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        project: String?,
        output: BuildCommandOutput
    ) throws -> BuildDependencyTree {
        try decode(BuildDependencyTree.self, #"{"dependencies": [], "truncated": false}"#)
    }

    func syncFingerprint(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        projects: [String],
        options: [String: ToolingJSONValue]
    ) throws -> BuildSyncState {
        BuildSyncState(fingerprint: fingerprint, watch: ["build.file"])
    }

    private func plan(_ arguments: [String], output: BuildProcessPlan.Output?) -> BuildProcessPlan {
        BuildProcessPlan(
            arguments: arguments,
            environment: ["FROM_PLAN": "1"],
            workingDirectory: "app",
            optionFingerprint: "o",
            output: output
        )
    }
}

@MainActor
private final class FakeToolResolver: BuildToolResolving {
    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(
            executableURL: URL(fileURLWithPath: "/tool/bin/fake"),
            environment: ["PATH": "/tool/bin"],
            executesProjectCode: false,
            version: nil
        )
    }
}

@MainActor
private final class FakeOptionsStore: BuildOptionsStoring {
    var values: [String: [String: ToolingJSONValue]] = [:]

    func options(workspaceURL: URL, buildSystemID: String) -> [String: ToolingJSONValue] {
        values[buildSystemID] ?? [:]
    }

    func setOptions(_ options: [String: ToolingJSONValue], workspaceURL: URL, buildSystemID: String) {
        values[buildSystemID] = options.isEmpty ? nil : options
    }
}

private final class FakeStateLocator: BuildSystemStateLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedURLs: [URL] = []
    private var removedURLs: [URL] = []

    var allocated: [URL] { lock.withLock { allocatedURLs } }
    var removed: [URL] { lock.withLock { removedURLs } }

    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL {
        URL(fileURLWithPath: "/state/\(pluginID)/\(buildSystemID)")
    }

    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL {
        let url = workspaceStateDirectory.appendingPathComponent("outputs/\(UUID().uuidString).json")
        lock.withLock { allocatedURLs.append(url) }
        return url
    }

    func removeOutputFile(_ url: URL) {
        lock.withLock { removedURLs.append(url) }
    }
}

private final class FakeBuildRunner: BuildCommandRunning, @unchecked Sendable {
    struct Script {
        let chunks: [String]
        let result: BuildCommandResult
    }

    let started = BuildTestGate()
    let cancelled = BuildTestGate()
    private let lock = NSLock()
    private var recorded: [BuildCommandRequest] = []
    private var configuredScript = Script(chunks: [], result: BuildCommandResult(termination: .exited(0)))
    private var blocks = false

    var requests: [BuildCommandRequest] { lock.withLock { recorded } }
    var script: Script {
        get { lock.withLock { configuredScript } }
        set { lock.withLock { configuredScript = newValue } }
    }
    var blocksUntilCancelled: Bool {
        get { lock.withLock { blocks } }
        set { lock.withLock { blocks = newValue } }
    }

    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult {
        lock.withLock { recorded.append(request) }
        started.open()
        if blocksUntilCancelled {
            let cancelled = cancelled
            await withTaskCancellationHandler {
                _ = await cancelled.waitUntilOpen()
            } onCancel: {
                cancelled.open()
            }
            throw CancellationError()
        }
        let script = script
        script.chunks.forEach(onOutput)
        return script.result
    }
}
