import Foundation
import Testing
import LitheCoreContracts
import LitheExecutionModule
@testable import Lithe

/// `lithe/host/run/start`, `run/stop` and `debug/start`: what the host resolves, starts and reports.
/// Rust Core's checks of the request are not repeated here; the decoder is a stub.
@MainActor
struct PluginRunHostServiceTests {
    // MARK: run/start

    @Test
    func aToolRunExpandsTheLaunchTemplateAndLetsThePluginsEnvironmentWin() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.decoder.runStart = { _ in
            makeRunStart(arguments: ["run", "."], workingDirectory: "sub", environment: ["A": "plugin", "B": "b"])
        }

        let result = try await fixture.call("run/start").get()

        let launch = try #require(fixture.window.launch)
        #expect(result == .object(["runID": .string(launch.runID)]))
        #expect(launch.title == "Run app")
        #expect(launch.executableURL.path == "/opt/tool/bin/tool")
        #expect(launch.arguments == ["--wrapped", "run", "."])
        #expect(launch.workingDirectory.path == "/fixture/workspace/sub")
        #expect(launch.environment["PATH"] == "/opt/tool/bin")
        #expect(launch.environment["A"] == "plugin")
        #expect(launch.environment["B"] == "b")
        // The user's layers pick the installation; project code is allowed as for any Run.
        #expect(fixture.tools.resolutions == [
            RunTools.Resolution(tool: "go", directory: "sub", workspace: PluginHostFixture.workspaceURL.path, projectCodeAllowed: true),
        ])
        #expect(fixture.decoder.workspaceRoots == [PluginHostFixture.workspaceURL])
    }

    @Test
    func aPackagedExecutableRunsFromThePluginPackageWithoutResolvingATool() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let package = try fixture.makePackage(executable: "bin/serve")
        fixture.backends.packages[RunHostFixture.pluginID] = package
        fixture.decoder.runStart = { _ in makeRunStart(executable: .packaged("bin/serve"), arguments: ["--port", "0"]) }

        _ = try await fixture.call("run/start").get()

        let launch = try #require(fixture.window.launch)
        #expect(launch.executableURL.path == package.appendingPathComponent("bin/serve").resolvingSymlinksInPath().path)
        #expect(launch.arguments == ["--port", "0"])
        #expect(fixture.tools.resolutions.isEmpty)
    }

    @Test
    func aPackagedExecutableThatIsMissingNotRunnableOrLinkedOutOfThePackageIsNotFound() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let package = try fixture.makePackage(executable: "bin/serve")
        try fixture.addFile("bin/data.txt", under: package, executable: false)
        let outside = try fixture.makePackage(executable: "tool")
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("bin/escape"), withDestinationURL: outside.appendingPathComponent("tool"))
        fixture.backends.packages[RunHostFixture.pluginID] = package

        for path in ["bin/missing", "bin/data.txt", "bin/escape"] {
            fixture.decoder.runStart = { _ in makeRunStart(executable: .packaged(path)) }
            let error = await fixture.failure("run/start")
            #expect(error?.code == .notFound, "\(path)")
        }
        #expect(fixture.window.launch == nil)
    }

    @Test
    func aToolWithNoUsableInstallationIsUnresolvedAndNothingStarts() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }

        fixture.tools.selection = nil
        let notInstalled = await fixture.failure("run/start")
        #expect(notInstalled?.code == .toolUnresolved)
        #expect(notInstalled?.details == ["tool": .string("go"), "reason": .string("notFound")])

        // The installation the user chose cannot run.
        fixture.tools.selection = RunTools.installation
        fixture.tools.resolveFailure = BuildToolResolutionError("The selected installation is broken.")
        let broken = await fixture.failure("run/start")
        #expect(broken?.code == .toolUnresolved)
        #expect(broken?.details == ["tool": .string("go"), "reason": .string("unusable")])

        // The definition's launch template cannot carry the plugin's arguments.
        fixture.tools.resolveFailure = nil
        fixture.tools.launchFailure = DefinedToolLaunchRejection(code: "plugin.toolchain.launchMismatch", message: "mismatch")
        let mismatch = await fixture.failure("run/start")
        #expect(mismatch?.code == .toolUnresolved)
        #expect(mismatch?.details == ["tool": .string("go"), "reason": .string("unusable")])

        #expect(fixture.window.launch == nil)
    }

    @Test
    func aWorkingDirectoryThatLeavesTheWorkspaceIsRefused() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.decoder.runStart = { _ in makeRunStart(workingDirectory: "../elsewhere") }

        let error = await fixture.failure("run/start")

        #expect(error?.code == .permissionDenied)
        #expect(fixture.window.launch == nil)
    }

    @Test
    func aConnectionDebugRunPassesTheDebugRequestToTheWindow() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let debug = PluginRunStart.Debug(configurationType: "go", target: .connection(port: 40000))
        fixture.decoder.runStart = { _ in makeRunStart(debug: debug) }

        _ = try await fixture.call("run/start").get()

        #expect(fixture.window.debug == debug)
    }

    @Test
    func aDebugTargetTheHostCannotStartYetIsRefusedBeforeAnythingRuns() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.decoder.runStart = { _ in makeRunStart(debug: .init(configurationType: "go", target: .launch)) }

        let error = await fixture.failure("run/start")

        #expect(error?.code == .unsupportedOption)
        #expect(error?.details == ["option": .string("debug.target")])
        #expect(fixture.tools.resolutions.isEmpty)
        #expect(fixture.window.launch == nil)
    }

    @Test
    func aWindowThatCannotRunAndAPluginWithoutABackendAreAnsweredWithTheirOwnCodes() async {
        let plain = FakePluginHostWindow(snapshot: PluginHostFixture.snapshot(windowID: UUID()))
        let withoutRunPort = RunHostFixture(owner: plain)
        defer { withoutRunPort.end() }
        for method in ["run/start", "debug/start"] {
            #expect(await withoutRunPort.failure(method)?.code == .unavailable, "\(method)")
        }

        let withoutBackend = RunHostFixture()
        defer { withoutBackend.end() }
        withoutBackend.backends.manifests = [:]
        for method in ["run/start", "debug/start"] {
            #expect(await withoutBackend.failure(method)?.code == .backendExited, "\(method)")
        }
        #expect(withoutBackend.window.launch == nil)
    }

    @Test
    func coreRejectionsReachTheBackendAsHostErrorsWithTheirCodeAndField() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let cases: [(code: String, field: String?, expected: PluginHostErrorCode)] = [
            ("plugin.run.invalidStart", "process.arguments", .invalidParams),
            ("plugin.debug.invalidStart", nil, .invalidParams),
            ("plugin.debug.unknownAdapter", "adapter", .notFound),
            ("plugin.debug.foreignAdapter", "adapter", .notFound),
            ("plugin.debug.limitExceeded", "configuration", .limitExceeded),
        ]
        for (code, field, expected) in cases {
            let rejection = DeclarativePluginRejection(code: code, message: "Core says no", field: field)
            fixture.decoder.runFailure = rejection
            fixture.decoder.debugFailure = rejection
            for method in ["run/start", "debug/start"] {
                let error = await fixture.failure(method)
                #expect(error?.code == expected, "\(method) \(code)")
                #expect(error?.details?["code"] == .string(code), "\(method) \(code)")
                #expect(error?.details?["field"] == field.map(ToolingJSONValue.string), "\(method) \(code)")
            }
        }
        #expect(fixture.window.launch == nil)
        #expect(fixture.window.debugStarts.isEmpty)
    }

    // MARK: The end of a run

    @Test
    func theEndIsReportedOnceToTheBackendSessionThatSawTheRunBegin() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let runID = try await fixture.startRun(session: "session-7")

        fixture.window.finish(runID: runID, exitCode: 3)
        fixture.window.finish(runID: runID, exitCode: 4)

        #expect(fixture.backends.exits == [
            RunBackends.Exit(pluginID: RunHostFixture.pluginID, sessionID: "session-7",
                             params: .object(["runID": .string(runID), "exitCode": .integer(3)])),
        ])
    }

    @Test
    func aRunTheUserStoppedIsReportedWithoutAnExitCode() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let runID = try await fixture.startRun()

        fixture.window.finish(runID: runID, exitCode: nil)

        #expect(fixture.backends.exits.map(\.params) == [.object(["runID": .string(runID)])])
    }

    @Test
    func theEndOfARunTheHostDoesNotKnowIsIgnored() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        _ = try await fixture.startRun()

        fixture.window.finish(runID: "another-run", exitCode: 1)

        #expect(fixture.backends.exits.isEmpty)
    }

    // MARK: Temporary files

    @Test
    func temporaryFilesAreWrittenForTheRunAndRemovedWhenItEnds() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.decoder.runStart = { directory in
            let path = directory!.appendingPathComponent("settings.json").path
            return makeRunStart(temporaryFiles: [PluginRunStart.TemporaryFile(path: path, contents: "{\"a\":1}")])
        }

        let runID = try await fixture.startRun()

        let directory = try #require(fixture.decoder.temporaryDirectories.last ?? nil)
        fixture.scratch.append(directory)
        #expect(try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8) == "{\"a\":1}")
        fixture.window.finish(runID: runID, exitCode: 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func aRunWithoutTemporaryFilesCreatesNoDirectory() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }

        _ = try await fixture.call("run/start").get()

        let directory = try #require(fixture.decoder.temporaryDirectories.last ?? nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func aWindowThatFailsToStartTheRunLeavesNoFilesAndNoRunToStop() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.window.startFailure = CocoaError(.fileWriteNoPermission)
        fixture.decoder.runStart = { directory in
            let path = directory!.appendingPathComponent("settings.json").path
            return makeRunStart(temporaryFiles: [PluginRunStart.TemporaryFile(path: path, contents: "x")])
        }

        let error = await fixture.failure("run/start")

        #expect(error?.code == .failed)
        let directory = try #require(fixture.decoder.temporaryDirectories.last ?? nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // The window was told to drop whatever it had begun, and the run is not known afterwards.
        let runID = try #require(fixture.window.stoppedRuns.first)
        _ = try await fixture.call("run/stop", ["runID": .string(runID)], context: false).get()
        #expect(fixture.window.stoppedRuns == [runID])
    }

    @Test
    func aRequestCancelledWhileTheRunStartsStopsTheRunAndStaysSilent() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        // The backend gave up waiting: the window cancels the task that serves the request.
        fixture.window.duringStart = { withUnsafeCurrentTask { $0?.cancel() } }

        let request = Task { @MainActor in await fixture.failure("run/start") }
        let error = await request.value

        #expect(error?.code == .cancelled)
        let launch = try #require(fixture.window.launch)
        #expect(fixture.window.stoppedRuns == [launch.runID])
        fixture.window.finish(runID: launch.runID, exitCode: nil)
        #expect(fixture.backends.exits.isEmpty)
    }

    // MARK: Run again

    @Test
    func runningAgainCallsTheRerunFunctionWithItsDataInTheWindowsContext() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let data = ToolingJSONValue.object(["target": .string("app")])
        fixture.decoder.runStart = { _ in makeRunStart(rerun: PluginRunStart.Rerun(function: "run.prepare", data: data)) }
        _ = try await fixture.call("run/start").get()

        let rerun = try #require(fixture.window.rerun)
        rerun()
        try #require(await fixture.backends.called.waitUntilOpen())

        #expect(fixture.backends.calls == [
            RunBackends.Call(function: "run.prepare", pluginID: RunHostFixture.pluginID, params: data, context: fixture.context.reference),
        ])
        #expect(fixture.window.reportedProblems.isEmpty)
    }

    @Test
    func aRerunFunctionThatFailsIsReportedToTheUser() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.backends.functionFailure = RerunFailure.rerunFailed
        fixture.decoder.runStart = { _ in
            makeRunStart(rerun: PluginRunStart.Rerun(function: "run.prepare", data: .object([:])))
        }
        _ = try await fixture.call("run/start").get()

        let rerun = try #require(fixture.window.rerun)
        rerun()
        try #require(await fixture.window.problemReported.waitUntilOpen())

        #expect(fixture.window.reportedProblems == [RerunFailure.rerunFailed.localizedDescription])
    }

    // MARK: run/stop

    @Test
    func stopEndsOnlyARunOfTheCallingPluginAndIgnoresOthers() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let runID = try await fixture.startRun()

        _ = try await fixture.call("run/stop", ["runID": .string(runID)], plugin: "dev.example.other", context: false).get()
        _ = try await fixture.call("run/stop", ["runID": .string("unknown")], context: false).get()
        #expect(fixture.window.stoppedRuns.isEmpty)

        let reply = try await fixture.call("run/stop", ["runID": .string(runID)], context: false).get()
        #expect(reply == .null)
        #expect(fixture.window.stoppedRuns == [runID])
    }

    @Test
    func stopNeedsExactlyOneOfRunIDAndSessionID() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }

        let both = await fixture.failure("run/stop", ["runID": .string("a"), "sessionID": .string("b")], context: false)
        let neither = await fixture.failure("run/stop", [:], context: false)
        let extra = await fixture.failure("run/stop", ["runID": .string("a"), "force": .bool(true)], context: false)

        #expect(both?.code == .invalidParams)
        #expect(neither?.code == .invalidParams)
        #expect(extra?.code == .invalidParams)
    }

    // MARK: debug/start

    @Test
    func aDebugStartGoesToTheWindowAndItsSessionCanBeStoppedByItsPlugin() async throws {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        let start = PluginDebugStart(adapterID: "dev.example.tool/go", request: "launch", label: "Debug app",
                                     configuration: .object(["program": .string("main.go")]))
        fixture.decoder.debugStart = start
        fixture.window.debugSessionID = "debug-1"

        let reply = try await fixture.call("debug/start", ["adapter": .string("go")]).get()

        #expect(reply == .object(["sessionID": .string("debug-1")]))
        #expect(fixture.window.debugStarts == [start])
        #expect(fixture.decoder.debugParams == [.object(["adapter": .string("go")])])

        _ = try await fixture.call("run/stop", ["sessionID": .string("debug-1")], plugin: "dev.example.other", context: false).get()
        #expect(fixture.window.stoppedSessions.isEmpty)
        _ = try await fixture.call("run/stop", ["sessionID": .string("debug-1")], context: false).get()
        #expect(fixture.window.stoppedSessions == ["debug-1"])

        // Once the session is gone, stopping it is a no-op.
        fixture.window.endDebugSession("debug-1")
        _ = try await fixture.call("run/stop", ["sessionID": .string("debug-1")], context: false).get()
        #expect(fixture.window.stoppedSessions == ["debug-1"])
    }

    @Test
    func aDebugSessionTheWindowFailedToStartIsAnErrorNotASession() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.window.startFailure = CocoaError(.fileNoSuchFile)

        let error = await fixture.failure("debug/start")

        #expect(error?.code == .failed)
        #expect(fixture.window.stoppedSessions.isEmpty)
    }

    @Test
    func aDebugStartCancelledWhileStartingStopsTheSession() async {
        let fixture = RunHostFixture()
        defer { fixture.end() }
        fixture.window.debugSessionID = "debug-2"
        fixture.window.duringStart = { withUnsafeCurrentTask { $0?.cancel() } }

        let request = Task { @MainActor in await fixture.failure("debug/start") }
        let error = await request.value

        #expect(error?.code == .cancelled)
        #expect(fixture.window.stoppedSessions == ["debug-2"])
    }
}

// MARK: - Support

private enum RerunFailure: Error, LocalizedError {
    case rerunFailed
    var errorDescription: String? { "The backend could not prepare the run." }
}

/// A decoded `run/start` with the plain defaults of these tests.
private func makeRunStart(
    executable: PluginRunStart.Executable = .tool("go"), arguments: [String] = [],
    workingDirectory: String = ".", environment: [String: String] = [:],
    temporaryFiles: [PluginRunStart.TemporaryFile] = [], debug: PluginRunStart.Debug? = nil,
    rerun: PluginRunStart.Rerun? = nil
) -> PluginRunStart {
    PluginRunStart(label: "Run app", executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                   environment: environment, temporaryFiles: temporaryFiles, debug: debug, rerun: rerun)
}

/// Stands in for Core: answers with what the test set, and records what the service asked.
private final class RunDecoder: PluginRunStartDecoding, @unchecked Sendable {
    var runStart: (URL?) -> PluginRunStart = { _ in makeRunStart() }
    var debugStart = PluginDebugStart(adapterID: "dev.example.tool/go", request: "launch", label: "Debug", configuration: .object([:]))
    var runFailure: (any Error)?
    var debugFailure: (any Error)?
    private(set) var workspaceRoots: [URL] = []
    private(set) var temporaryDirectories: [URL?] = []
    private(set) var debugParams: [ToolingJSONValue] = []

    func decodeRunStart(manifest _: Data, workspaceRoot: URL, temporaryDirectory: URL?,
                        params _: ToolingJSONValue) throws -> PluginRunStart {
        workspaceRoots.append(workspaceRoot)
        temporaryDirectories.append(temporaryDirectory)
        if let runFailure { throw runFailure }
        return runStart(temporaryDirectory)
    }

    func decodeDebugStart(manifest _: Data, params: ToolingJSONValue) throws -> PluginDebugStart {
        debugParams.append(params)
        if let debugFailure { throw debugFailure }
        return debugStart
    }
}

/// The installed tools: one installation by default, and whatever the test makes of it.
@MainActor
private final class RunTools: DefinedToolchainResolving, DefinedToolLaunching {
    struct Resolution: Equatable {
        let tool: String
        let directory: String
        let workspace: String
        let projectCodeAllowed: Bool
    }

    static let installation = ResolvedDefinedToolchain(
        executable: URL(fileURLWithPath: "/opt/tool/bin/tool"), environment: ["PATH": "/opt/tool/bin", "A": "tool"],
        projectCode: false, version: "1.0", home: "/opt/tool")

    var selection: ResolvedDefinedToolchain? = RunTools.installation
    var resolveFailure: (any Error)?
    var launchFailure: DefinedToolLaunchRejection?
    private(set) var resolutions: [Resolution] = []

    func resolve(tool: String, directory: String, workspace: URL, environment _: [String: String],
                 minimumVersion _: String?, projectCodeAllowed: Bool) async throws -> ResolvedDefinedToolchain? {
        resolutions.append(Resolution(tool: tool, directory: directory, workspace: workspace.path, projectCodeAllowed: projectCodeAllowed))
        if let resolveFailure { throw resolveFailure }
        return selection
    }

    func launch(of selection: ResolvedDefinedToolchain, tool _: String, arguments: [String]) throws -> DefinedToolLaunch {
        if let launchFailure { throw launchFailure }
        return DefinedToolLaunch(executable: selection.executable.path, arguments: ["--wrapped"] + arguments)
    }
}

/// The plugin backends: their manifests and packages, the functions called, the exits heard.
@MainActor
private final class RunBackends: PluginRunBackendLink {
    struct Call: Equatable {
        let function: String
        let pluginID: String
        let params: ToolingJSONValue
        let context: PluginWorkspaceContextReference?
    }

    struct Exit: Equatable {
        let pluginID: String
        let sessionID: String
        let params: ToolingJSONValue
    }

    var manifests: [String: Data] = [:]
    var packages: [String: URL] = [:]
    var functionFailure: (any Error)?
    private(set) var calls: [Call] = []
    private(set) var exits: [Exit] = []
    let called = TestGate()

    func manifest(ofPlugin pluginID: String) -> Data? { manifests[pluginID] }
    func packageURL(ofPlugin pluginID: String) -> URL? { packages[pluginID] }

    func notifyRunDidExit(pluginID: String, sessionID: String, params: ToolingJSONValue) {
        exits.append(Exit(pluginID: pluginID, sessionID: sessionID, params: params))
    }

    func declaresBackend(_: String) -> Bool { true }
    func pluginFunctions(ofPlugin _: String) async throws -> [String] { [] }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String, timeout _: Duration,
        progress _: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        try await invokePluginFunction(functionID, params: params, ofPlugin: pluginID, context: nil, timeout: .seconds(1), progress: { _ in })
    }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String,
        context: PluginWorkspaceContextReference?, timeout _: Duration,
        progress _: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        calls.append(Call(function: functionID, pluginID: pluginID, params: params, context: context))
        called.open()
        if let functionFailure { throw functionFailure }
        return .null
    }
}

/// A window that shows runs and debug sessions, and lets the test end them.
@MainActor
private final class RunWindow: PluginHostWindowPort, PluginRunWindowPort {
    var hostSnapshot: PluginHostWindowSnapshot? = PluginHostFixture.snapshot(windowID: UUID())
    let hostMessages = PluginHostMessageFeatureModel()
    var startFailure: (any Error)?
    /// Runs while the window starts a run or a session, to model the request changing under it.
    var duringStart: (@MainActor () -> Void)?
    var debugSessionID = "debug-1"
    private(set) var launch: PluginRunLaunch?
    private(set) var debug: PluginRunStart.Debug?
    private(set) var rerun: (@MainActor () -> Void)?
    private(set) var onEnd: (@MainActor (PluginRunEnd) -> Void)?
    private(set) var stoppedRuns: [String] = []
    private(set) var debugStarts: [PluginDebugStart] = []
    private(set) var stoppedSessions: [String] = []
    private(set) var reportedProblems: [String] = []
    private var debugEnd: (@MainActor (String) -> Void)?
    let problemReported = TestGate()

    func hostStartPluginRun(_ launch: PluginRunLaunch, debug: PluginRunStart.Debug?, rerun: (@MainActor @Sendable () -> Void)?,
                            onEnd: @escaping @MainActor @Sendable (PluginRunEnd) -> Void) async throws {
        self.launch = launch
        self.debug = debug
        self.rerun = rerun
        self.onEnd = onEnd
        duringStart?()
        if let startFailure { throw startFailure }
    }

    func hostStopPluginRun(runID: String) { stoppedRuns.append(runID) }

    func hostStartPluginDebugSession(_ start: PluginDebugStart, onEnd: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        debugStarts.append(start)
        debugEnd = onEnd
        duringStart?()
        if let startFailure { throw startFailure }
        return debugSessionID
    }

    func hostStopPluginDebugSession(_ sessionID: String) { stoppedSessions.append(sessionID) }

    func hostReportPluginRunProblem(_ message: String) {
        reportedProblems.append(message)
        problemReported.open()
    }

    /// The process of the run ended; `exitCode` is nil when the user stopped it.
    func finish(runID: String, exitCode: Int32?) {
        onEnd?(PluginRunEnd(runID: runID, exitCode: exitCode))
    }

    func endDebugSession(_ sessionID: String) { debugEnd?(sessionID) }

    func hostDocumentState(at url: URL, flushingEditor: Bool) async -> PluginHostDocumentState? { nil }
    func hostOpenDocument(at url: URL, activation: PluginHostEditorActivation) async -> PluginHostDocumentState? { nil }
    func hostPlaceCaret(in url: URL, at position: PluginHostPosition) {}
    func hostNoteMessageLimit(pluginName: String) {}
}

/// The service with one local window and every collaborator stubbed.
@MainActor
private final class RunHostFixture {
    static let pluginID = "dev.example.tool"

    let contexts = PluginWorkspaceContexts()
    let window = RunWindow()
    let decoder = RunDecoder()
    let tools = RunTools()
    let backends = RunBackends()
    let service: PluginRunHostService
    let context: PluginWorkspaceContext
    /// Held so the context keeps its owner: the contexts only know it weakly.
    private let owner: any PluginHostWindowPort
    private let subscriptions = PluginHostSubscriptions()
    /// Directories this test created for itself, removed in `end()`.
    var scratch: [URL] = []

    /// `owner` is the window that owns the workspace context; by default the window that can run.
    init(owner: (any PluginHostWindowPort)? = nil) {
        self.owner = owner ?? window
        service = PluginRunHostService(
            contexts: contexts, decoder: decoder, tools: tools, fileStorage: MacFileStorage(),
            baseEnvironment: { ["HOME": "/fixture/home"] })
        service.backends = backends
        backends.manifests[Self.pluginID] = Data("{}".utf8)
        context = contexts.open(owner: self.owner, rootURL: PluginHostFixture.workspaceURL, remote: nil)
    }

    func end() {
        contexts.close(owner: owner)
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        if let launch = window.launch {
            try? FileManager.default.removeItem(at: MacFileStorage().temporaryDirectory()
                .appendingPathComponent("lithe-plugin-run-\(launch.runID)", isDirectory: true))
        }
    }

    func call(_ method: String, _ params: [String: ToolingJSONValue] = [:], plugin: String = RunHostFixture.pluginID,
              session: String = "session-1", context: Bool = true) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        let request = PluginHostRequest(id: UUID().uuidString, method: "lithe/host/" + method, service: "run", params: .object(params))
        return await service.answer(PluginHostCall(
            pluginID: plugin, sessionID: session, request: request, context: context ? self.context : nil,
            params: params, subscriptions: subscriptions))
    }

    func failure(_ method: String, _ params: [String: ToolingJSONValue] = [:], context: Bool = true) async -> PluginHostServiceError? {
        if case .failure(let error) = await call(method, params, context: context) { return error }
        return nil
    }

    /// Starts the default run and returns its ID.
    func startRun(session: String = "session-1") async throws -> String {
        let reply = try await call("run/start", session: session).get()
        guard case .object(let object) = reply, case .string(let id)? = object["runID"] else { throw PluginHostArguments.invalid }
        return id
    }

    /// A plugin package directory holding one executable file.
    func makePackage(executable relativePath: String) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-run-host-test-\(UUID().uuidString)", isDirectory: true)
        scratch.append(package)
        try addFile(relativePath, under: package, executable: true)
        return package
    }

    func addFile(_ relativePath: String, under package: URL, executable: Bool) throws {
        let file = package.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
    }
}
