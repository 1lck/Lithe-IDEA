import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

/// Explicit integration: the public Node SDK builds a native program, then
/// the production Registry and transport hand it to a real LLDB DAP adapter.
@Suite("Native Provider LLDB integration", .serialized)
@MainActor
struct MacNativeProviderDebugIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_C_NODE_SDK"] != nil,
                   "Requires the Node SDK source, Node, Clang and LLDB DAP paths"))
    func providerBuildsThenDebugsANativeProgramThroughTheRegistry() async throws {
        let environment = ProcessInfo.processInfo.environment
        func selected(_ key: String) throws -> URL {
            URL(fileURLWithPath: try #require(environment[key]))
        }
        let sdk = try selected("LITHE_STAGE_C_NODE_SDK")
        let node = try selected("LITHE_STAGE_C_NODE")
        let clang = try selected("LITHE_STAGE_C_CLANG")
        let lldb = try selected("LITHE_STAGE_C_LLDB_DAP")
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("provider-lldb-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        // Preserve the example's relative SDK import. All mutations are test
        // inputs in this private copy, never the SDK checkout or an installation.
        let copiedSDK = scratch.appendingPathComponent("sdk")
        let package = copiedSDK.appendingPathComponent("examples/sample-native-build")
        try files.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: sdk.appendingPathComponent("src"), to: copiedSDK.appendingPathComponent("src"))
        try files.copyItem(at: sdk.appendingPathComponent("examples/sample-native-build"), to: package)
        let manifestFile = package.appendingPathComponent("plugin.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        var adapters = try #require(manifest["debugAdapters"] as? [[String: Any]])
        adapters[0]["launch"] = ["process": ["launch": ["kind": "systemCommand", "commands": ["lldb-dap"]]], "transport": "stdio"]
        adapters[0]["configurations"] = ["launch": [
            "arguments": ["disableASLR": false],
            "targetBindings": ["program": "target.path", "cwd": "target.workingDirectory", "args": "target.arguments", "env": "target.environment"]]]
        manifest["debugAdapters"] = adapters
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestFile)
        let before = try MacNativeBuildProviderIntegrationTests.inventory(copiedSDK)
        let workspace = scratch.appendingPathComponent("workspace")
        let app = workspace.appendingPathComponent("nested/app")
        try files.createDirectory(at: app, withIntermediateDirectories: true)
        let sourceFile = app.appendingPathComponent("main.c")
        try Data("""
        #include <stdio.h>
        int main(int argc, char **argv) {
            int value = 40;
            value += 2;
            printf("%s:%d\\n", argc > 1 ? argv[1] : "missing", value);
            return 0;
        }

        """.utf8).write(to: sourceFile)
        // Explicit source paths keep the compiler's DWARF file identity and
        // DAP source identity equal across macOS's /var -> /private/var alias.
        let config: [String: Any] = ["projects": [["name": "app", "path": "app",
            "build": [clang.path, "-g", "-O0", sourceFile.path, "-o", "native-program"],
            "run": ["command": "node", "arguments": [], "debugProgram": "native-program"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: workspace.appendingPathComponent("nested/lithe-sample.json"))

        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let declarations = RustDeclarativePluginOperations(core: core)
        let operations = RustBuildSystemOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: manifestFile))
        let installed = InstalledPluginPackage(descriptor: descriptor, installation: PluginInstallationRecord(
            pluginID: descriptor.id, activeVersion: descriptor.pluginManifest.version, origin: .marketplace, status: .installed), packageURL: package)
        let entry = try #require(PluginDebugAdapterEntry.qualifiedIndex(of: [installed]).values.first)
        let target = BuildSystemTarget(manifest: descriptor.normalizedManifest, buildSystemID: "sample")
        let provider = BuildProviderTarget(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystemID: "sample", workspaceURL: workspace)
        let pluginSource = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let resolver = MacPluginLanguageServerLaunchResolver(planner: declarations,
            directories: MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state")), settings: InMemoryPluginSettings())
        let runtime = NativeDebugNodeRuntime(node: node, environment: environment)
        let released = TestGate()
        let sessions = MacBuildProviderSessions(launchResolver: resolver, tools: runtime, versionChecker: declarations,
            runtime: runtime, core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0)
                released.open()
            })
        let trace = NativeDebugTrace()
        let processScope = "native-debug-test-\(UUID().uuidString)"
        let manager = DebugAdapterSessionManager(providers: [entry.provider(languages: [])]) { _, _ in
            CoreDebugAdapterProtocolSession(adapterID: entry.adapter.id,
                transport: NativeDebugRecordingTransport(wrapping: MacPluginDebugAdapterTransport(adapterID: entry.adapter.id, resolve: {
                    try resolver.resolveDebugAdapter(pluginID: descriptor.id.rawValue, adapterID: entry.adapter.id,
                        manifest: descriptor.normalizedManifest, packageURL: package, workspaceRootURL: $0)
                }, makeProcess: { NativeDebugScopedProcess(scope: processScope) }, core: core, findCommand: { commands in
                    #expect(commands == ["lldb-dap"])
                    return lldb
                }), trace: trace), core: core, deadlineScheduler: MacDebugOperationDeadlineScheduler())
        }
        manager.onSessionStateChange = { _, _, state in if state == .ready { trace.ready.open() } }
        manager.onSessionEvent = { _, _, event in trace.record(event) }
        let outcome: Result<Void, Error>
        do {
            let context = BuildPlanContext(root: "nested", options: [:], pluginDirectory: package,
                workspaceStateDirectory: scratch.appendingPathComponent("workspace-state"))
            guard case .provider(let modelRequest) = try operations.modelPlan(target, context: context, outputFile: nil, providerHints: BuildProviderHints()) else {
                throw NativeDebugIntegrationError.unexpectedPlan
            }
            let rawModel = try await sessions.send(modelRequest, to: provider, timeout: .seconds(15))
            let model = try operations.decodeModel(target, workspaceURL: workspace, root: context.root,
                output: .providerResult(rawModel), options: [:])
            let project = try #require(model.projects.first)
            let application = try #require(model.targets.first)
            let request = try operations.prepareDebugPlan(target, context: context, run: "application",
                project: BuildSelection(project: project), selectedTarget: BuildSelection(target: application), userArguments: ["two words"])
            let prepared = try await sessions.prepareDebug(request, on: provider, timeout: .seconds(15)) { trace.buildOutput += $0.output ?? "" }
            let preparation = try operations.decodeDebugPreparation(target, workspaceURL: workspace, root: context.root,
                run: "application", result: prepared)
            let launch = try MacBuildDebugLaunchResolver(planner: declarations, entry: { _ in entry }, generation: { 1 })
                .resolve(source: pluginSource, preparation: preparation, workspaceURL: workspace, title: "Native integration")
            #expect(manager.provider(for: sourceFile) == nil, "An executable-only adapter requires explicit Registry selection")
            try manager.setBreakpoints([DebugSourceBreakpoint(line: 4)], in: sourceFile)
            let binary = workspace.appendingPathComponent(preparation.program)
            _ = try manager.activate(for: binary, rootURL: workspace, adapterProviderID: launch.adapterProviderID)
            try #require(await trace.ready.waitUntilOpen(timeout: .seconds(10)), "LLDB initialize timed out: \(trace.output)")
            let debugging = try manager.launch(for: binary, rootURL: workspace, configuration: launch)
            try #require(await trace.stopped.waitUntilOpen(timeout: .seconds(10)), "Native breakpoint timed out: \(trace.output)\n\(trace.protocolLog)")
            let thread = try #require(trace.thread)
            let inspected = TestGate()
            var stack: Result<[DebugStackFrame], Error>?
            debugging.requestStackTrace(threadID: thread) { result in stack = result; inspected.open() }
            try #require(await inspected.waitUntilOpen(timeout: .seconds(10)), "Native stack request timed out")
            let frames = try #require(stack).get()
            #expect(frames.first?.name.contains("main") == true)
            #expect(frames.first?.line == 4)
            #expect(trace.verifiedBreakpoint)
            debugging.execute(DebugExecutionCommand.continueExecution, threadID: thread)
            try #require(await trace.terminated.waitUntilOpen(timeout: .seconds(10)), "Native program did not terminate: \(trace.output)")
            #expect(trace.exitCode == 0)
            #expect(trace.output.contains("two words:42"))
            #expect(try await sessions.pluginFunctions(of: provider).isEmpty)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        // Pin descendants while LLDB still owns them: debugserver can create
        // a new session and discard inherited environment variables.
        let adapterRoots = MacProcessScopeScanner.processes(in: processScope).map(\.info.identity)
        let owned = MacProcessScopeScanner.retainedIdentities(adapterRoots, snapshot: MacProcessTable.snapshot())
        manager.stopAll()
        // The native adapter's bounded OS cleanup runs on its worker queue,
        // never on the test's cooperative executor or the main actor.
        let remaining = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: MacProcessScopeScanner.terminate(Array(owned), gracePeriod: 0))
            }
        }
        #expect(remaining.isEmpty)
        sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(manager.activeSessionIDs.isEmpty)
        #expect(try MacNativeBuildProviderIntegrationTests.inventory(copiedSDK) == before)
        try outcome.get()
    }
}

private enum NativeDebugIntegrationError: Error { case unexpectedPlan }

@MainActor
private final class NativeDebugTrace {
    let ready = TestGate(), stopped = TestGate(), terminated = TestGate()
    var thread: Int?
    var exitCode: Int?
    var verifiedBreakpoint = false
    var output = ""
    var buildOutput = ""
    var protocolLog = ""
    func record(_ event: DebugAdapterEvent) {
        switch event {
        case .stopped(_, let threadID, _): thread = threadID; stopped.open()
        case .terminated(let code): exitCode = code; terminated.open()
        case .breakpoint(let breakpoint): verifiedBreakpoint = verifiedBreakpoint || breakpoint.verified
        case .output(_, let text): output += text
        default: break
        }
    }
}

@MainActor
private final class NativeDebugRecordingTransport: DebugAdapterTransport {
    let wrapped: any DebugAdapterTransport
    let trace: NativeDebugTrace
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?
    var isRunning: Bool { wrapped.isRunning }
    init(wrapping wrapped: any DebugAdapterTransport, trace: NativeDebugTrace) {
        self.wrapped = wrapped; self.trace = trace
        wrapped.onData = { [weak self] data in
            self?.trace.protocolLog += "<- " + String(decoding: data, as: UTF8.self) + "\n"
            self?.onData?(data)
        }
        wrapped.onErrorOutput = { [weak self] data in self?.onErrorOutput?(data) }
        wrapped.onTermination = { [weak self] code in self?.onTermination?(code) }
    }
    func start(rootURL: URL) throws { try wrapped.start(rootURL: rootURL) }
    func send(_ data: Data) throws {
        trace.protocolLog += "-> " + String(decoding: data, as: UTF8.self) + "\n"
        try wrapped.send(data)
    }
    func stop() { wrapped.stop() }
}

/// Adds a private cleanup scope to the real adapter process without mutating
/// the test runner's environment or changing process execution behavior.
private final class NativeDebugScopedProcess: RawProcessSession, @unchecked Sendable {
    let wrapped = MacRawProcessSession()
    let scope: String
    init(scope: String) { self.scope = scope }
    var isRunning: Bool { wrapped.isRunning }
    var onOutput: (@Sendable (Data) -> Void)? { get { wrapped.onOutput } set { wrapped.onOutput = newValue } }
    var onError: (@Sendable (Data) -> Void)? { get { wrapped.onError } set { wrapped.onError = newValue } }
    var onTermination: (@Sendable (Int32) -> Void)? { get { wrapped.onTermination } set { wrapped.onTermination = newValue } }
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)? { get { wrapped.onStateChange } set { wrapped.onStateChange = newValue } }
    func start(_ request: ProcessRequest) throws {
        var environment = request.environment ?? [:]
        environment[MacProcessScope.environmentKey] = scope
        try wrapped.start(ProcessRequest(operationID: request.operationID, executablePath: request.executablePath,
            arguments: request.arguments, workingDirectory: request.workingDirectory, environment: environment,
            standardInput: request.standardInput, keepsStandardInputOpen: request.keepsStandardInputOpen,
            timeoutMilliseconds: request.timeoutMilliseconds))
    }
    func send(_ input: Data) throws { try wrapped.send(input) }
    func stop() { wrapped.stop() }
}

/// The caller selects Node explicitly; every process and protocol request is real.
@MainActor
private final class NativeDebugNodeRuntime: BuildToolResolving, LanguageToolRuntimePort {
    let node: URL
    let environment: [String: String]
    init(node: URL, environment: [String: String]) { self.node = node; self.environment = environment }
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: node, environment: environment, executesProjectCode: false, version: nil)
    }
    func executableOnPath(_ name: String) -> URL? { name == "node" ? node : nil }
    func executableURL(at path: String) -> URL? { path == node.path ? node : nil }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { environment }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}
