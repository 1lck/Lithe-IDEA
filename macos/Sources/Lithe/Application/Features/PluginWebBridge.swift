import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule

// Note: 插件网页内容与宿主窗口的分工见 .agents/notes/implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md

/// One plugin web window as the host loads it: the installed package, the
/// page inside it, and the build systems the page may reach.
struct PluginWebWindow: Equatable, Sendable {
    let pluginID: String
    let pluginName: String
    let windowID: String
    /// Package-relative `.html` entry that Core already checked.
    let entry: String
    let packageURL: URL
    let buildSystemIDs: Set<String>
    /// Only local development packages let their author open Web Inspector.
    let isInspectable: Bool
}

/// A bridge refusal with a code of the shared contract.
struct PluginWebBridgeFailure: Error, Equatable {
    let code: String
    let message: String
    /// The plugin's own code of a failed function, passed to its page as is.
    var pluginErrorCode: String?

    static func forbidden(_ message: String) -> Self { .init(code: "plugin.web.forbidden", message: message) }
    static func invalidRequest(_ message: String) -> Self { .init(code: "plugin.web.invalidRequest", message: message) }
    static func unknownMethod(_ method: String) -> Self {
        .init(code: "plugin.web.unknownMethod", message: "The host has no bridge method \(method).")
    }
    static func invalidSelection(_ message: String) -> Self { .init(code: "plugin.build.invalidSelection", message: message) }
    static func unavailable(_ message: String) -> Self { .init(code: "plugin.build.unavailable", message: message) }
}

/// A page asks to start a build tool. Arguments the page typed in are shown
/// every time; otherwise one answer covers the plugin in this workspace.
struct PluginWebProcessConsent: Equatable, Sendable {
    let pluginID: String
    let pluginName: String
    let workspaceURL: URL
    let action: String
    let userArguments: [String]
}

/// The build feature as a page may use it: the same entry points as the
/// host's own build controls.
@MainActor
protocol PluginWebBuildAccess: AnyObject {
    var entries: [BuildSystemEntry] { get }
    var isDetecting: Bool { get }
    var currentRunID: UUID? { get }
    var changes: AnyPublisher<Void, Never> { get }
    var runEnded: AnyPublisher<BuildRunEnd, Never> { get }
    func loadModel(_ entryID: String)
    func runTask(_ entryID: String, request: BuildTaskRequest, title: String) -> UUID?
    func runTests(_ entryID: String, request: BuildTestRequest, title: String) -> UUID?
    func loadDependencies(_ entryID: String, project: BuildModel.Project?)
    func setOption(_ entryID: String, optionID: String, value: ToolingJSONValue?)
    func stopRun()
    /// Functions the instance's provider process registers; starts it.
    func pluginFunctions(_ entryID: String) async throws -> [String]
    func invokePluginFunction(
        _ entryID: String, functionID: String, params: ToolingJSONValue, timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue
}

extension BuildSystemsFeatureModel: PluginWebBuildAccess {
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
}

/// What a page may cause in its host window.
@MainActor
protocol PluginWebBridgeHost: AnyObject {
    var pluginWebWorkspaceURL: URL? { get }
    /// The build feature of the open workspace, activated on request.
    func pluginWebBuildSystems(activate: Bool) async -> (any PluginWebBuildAccess)?
    func pluginWebShowBuildOutput()
    /// Opens a workspace file at a 1-based line and column; false when it does not exist.
    func pluginWebOpenFile(_ url: URL, line: Int?, column: Int?) -> Bool
    func pluginWebConfirmProcessStart(_ consent: PluginWebProcessConsent) async -> Bool
}

/// Page state kept by the host, per window and workspace.
@MainActor
protocol PluginWebStateStoring: AnyObject {
    func state(pluginID: String, windowID: String, workspaceURL: URL) -> Data?
    func setState(_ data: Data?, pluginID: String, windowID: String, workspaceURL: URL) throws
}

/// Process-lifetime fallback for hosts and tests without platform storage.
@MainActor
final class MemoryPluginWebStateStore: PluginWebStateStoring {
    private var values: [String: Data] = [:]

    func state(pluginID: String, windowID: String, workspaceURL: URL) -> Data? {
        values[[pluginID, windowID, workspaceURL.standardizedFileURL.path].joined(separator: "\n")]
    }

    func setState(_ data: Data?, pluginID: String, windowID: String, workspaceURL: URL) throws {
        values[[pluginID, windowID, workspaceURL.standardizedFileURL.path].joined(separator: "\n")] = data
    }
}

/// Answers one page's `lithe.request` calls (bridge version 1) and sends it
/// the bridge events. Every method is checked here: the page reaches only
/// its own plugin's build systems and the workspace it was opened in, and
/// anything that starts a build tool goes through the host's consent.
@MainActor
final class PluginWebBridge {
    static let stateLimit = 64 * 1024
    static let messageLimit = 1024 * 1024
    /// Function calls one page may keep running at once.
    static let functionCallLimit = 16

    let window: PluginWebWindow
    /// Delivers an event and its JSON payload to the page.
    var emit: ((String, ToolingJSONValue) -> Void)?

    private weak var host: (any PluginWebBridgeHost)?
    private let stateStore: any PluginWebStateStoring
    private let workspaceURL: URL?
    private weak var build: (any PluginWebBuildAccess)?
    private var observations: [AnyCancellable] = []
    private var runs: [String: Run] = [:]
    /// Function calls from the moment they are accepted, through consent,
    /// until they end, by the page's call ID or a host-made one.
    private var functionCalls: [String: FunctionCall] = [:]
    /// Every call ID the page has used; an ID is never accepted twice, so
    /// late progress of an ended call cannot be mistaken for a new one.
    private var usedCallIDs: Set<String> = []
    private var lastInstances: ToolingJSONValue?
    private var waiters: [Waiter] = []
    private var isCheckScheduled = false
    private var isClosed = false
    private let requestTimeout: Duration

    private struct Run {
        let serviceRunID: UUID
        let entryID: String
        var isAnnounced = false
        var isFinished = false
    }

    /// Holds its slot under the call limit while consent is pending, so a
    /// cancel that arrives before the function starts still stops it.
    @MainActor
    private final class FunctionCall {
        private(set) var isCancelled = false
        var task: Task<ToolingJSONValue, Error>?

        func cancel() {
            isCancelled = true
            task?.cancel()
        }
    }

    private struct Waiter {
        let id: UUID
        let isSatisfied: @MainActor () -> Bool
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    init(
        window: PluginWebWindow, host: any PluginWebBridgeHost, stateStore: any PluginWebStateStoring,
        requestTimeout: Duration = .seconds(15 * 60)
    ) {
        self.window = window
        self.host = host
        self.stateStore = stateStore
        self.requestTimeout = requestTimeout
        workspaceURL = host.pluginWebWorkspaceURL?.standardizedFileURL
    }

    /// Ends event delivery and releases pending requests.
    func close() {
        isClosed = true
        emit = nil
        observations.removeAll()
        let calls = functionCalls
        functionCalls.removeAll()
        usedCallIDs.removeAll()
        calls.values.forEach { $0.cancel() }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.timeout.cancel(); $0.continuation.resume(returning: false) }
    }

    /// Handles one JSON message `{ method, params }` and returns the JSON
    /// reply `{ ok }` or `{ error: { code, message } }` for the page script.
    func handle(_ message: String) async -> String {
        let reply: ToolingJSONValue
        do {
            guard message.utf8.count <= Self.messageLimit,
                  case .object(let body)? = try? JSONDecoder().decode(ToolingJSONValue.self, from: Data(message.utf8)),
                  case .string(let method)? = body["method"],
                  Set(body.keys).isSubset(of: ["method", "params"]) else {
                throw PluginWebBridgeFailure.invalidRequest("A request is { method, params } JSON of at most 1 MiB.")
            }
            reply = .object(["ok": try await handle(method: method, params: body["params"] ?? .null)])
        } catch let failure as PluginWebBridgeFailure {
            var error: [String: ToolingJSONValue] = ["code": .string(failure.code), "message": .string(failure.message)]
            if let code = failure.pluginErrorCode { error["pluginErrorCode"] = .string(code) }
            reply = .object(["error": .object(error)])
        } catch {
            reply = .object(["error": .object([
                "code": .string("plugin.web.invalidRequest"), "message": .string(error.localizedDescription)
            ])])
        }
        let data = (try? JSONEncoder().encode(reply)) ?? Data(#"{"error":{"code":"plugin.web.invalidRequest","message":""}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func handle(method: String, params: ToolingJSONValue) async throws -> ToolingJSONValue {
        guard !isClosed else { throw PluginWebBridgeFailure.forbidden("The page was closed.") }
        let known: Set<String> = [
            "build.instances", "build.refresh", "build.runTask", "build.runTests", "build.cancel",
            "build.dependencies", "build.setOptions", "workspace.openFile", "ui.getState", "ui.setState",
            "functions.list", "functions.invoke", "functions.cancel"
        ]
        guard known.contains(method) else { throw PluginWebBridgeFailure.unknownMethod(method) }
        let workspaceURL = try currentWorkspace()
        switch method {
        case "build.instances":
            _ = try Parameters(params, allowed: [])
            return try await instances()
        case "build.refresh":
            let params = try Parameters(params, allowed: ["instance"])
            let (build, entry) = try await entry(params)
            // Only a static model is read without starting a process.
            if let source = entry.instance.modelSource, source != .static {
                try await consent(String(localized: "Load the \(entry.instance.displayName) model"), workspaceURL: workspaceURL)
            }
            build.loadModel(entry.id)
            return .object([:])
        case "build.runTask":
            return try await runTask(Parameters(
                params, allowed: ["instance", "task", "project", "target", "modelTask", "userArguments"]
            ), workspaceURL: workspaceURL)
        case "build.runTests":
            return try await runTests(Parameters(
                params, allowed: ["instance", "project", "target", "suite", "case"]
            ), workspaceURL: workspaceURL)
        case "build.cancel":
            let run = try Parameters(params, allowed: ["run"]).string("run")
            guard let tracked = runs[run] else { throw PluginWebBridgeFailure.invalidRequest("This page started no run \(run).") }
            if !tracked.isFinished, build?.currentRunID == tracked.serviceRunID { build?.stopRun() }
            return .object([:])
        case "build.dependencies":
            return try await dependencies(Parameters(params, allowed: ["instance", "project"]), workspaceURL: workspaceURL)
        case "build.setOptions":
            return try await setOptions(Parameters(params, allowed: ["instance", "values"]))
        case "workspace.openFile":
            return try openFile(Parameters(params, allowed: ["path", "line", "column"]), workspaceURL: workspaceURL)
        case "functions.list":
            return try await listFunctions(Parameters(params, allowed: ["instance"]), workspaceURL: workspaceURL)
        case "functions.invoke":
            return try await invokeFunction(
                Parameters(params, allowed: ["instance", "function", "params", "call"]), workspaceURL: workspaceURL
            )
        case "functions.cancel":
            let call = try Parameters(params, allowed: ["call"]).string("call", limit: 128)
            // A call that already ended is cancelled as a no-op. One still
            // awaiting consent is marked and never starts.
            functionCalls[call]?.cancel()
            return .object([:])
        case "ui.getState":
            _ = try Parameters(params, allowed: [])
            guard let data = stateStore.state(pluginID: window.pluginID, windowID: window.windowID, workspaceURL: workspaceURL),
                  data.count <= Self.stateLimit,
                  let state = try? JSONDecoder().decode(ToolingJSONValue.self, from: data) else {
                return .object(["state": .null])
            }
            return .object(["state": state])
        default:
            guard let state = try Parameters(params, allowed: ["state"]).values["state"] else {
                throw PluginWebBridgeFailure.invalidRequest("state is required; use null to clear it.")
            }
            let data = state == .null ? nil : try JSONEncoder().encode(state)
            guard (data?.count ?? 0) <= Self.stateLimit else {
                throw PluginWebBridgeFailure.invalidRequest("The state is larger than 64 KiB.")
            }
            try stateStore.setState(data, pluginID: window.pluginID, windowID: window.windowID, workspaceURL: workspaceURL)
            return .object([:])
        }
    }

    // MARK: Build systems

    private func instances() async throws -> ToolingJSONValue {
        guard !window.buildSystemIDs.isEmpty else { return .object(["instances": .array([])]) }
        guard let build = try await buildAccess() else {
            throw PluginWebBridgeFailure.unavailable("Build systems are unavailable.")
        }
        if build.isDetecting {
            let completed = await wait { [weak build] in build?.isDetecting != true }
            _ = try currentWorkspace()
            guard completed else { throw PluginWebBridgeFailure.unavailable("Detecting build systems timed out.") }
        }
        return .object(["instances": instancesJSON(build)])
    }

    private func runTask(_ params: Parameters, workspaceURL: URL) async throws -> ToolingJSONValue {
        let (build, entry) = try await entry(params)
        let taskID = try params.string("task", limit: 256)
        guard let task = entry.declaration.tasks.first(where: { $0.id == taskID }) else {
            throw PluginWebBridgeFailure.unavailable("\(entry.instance.displayName) declares no task \(taskID).")
        }
        let modelTask = try params.selection("modelTask").map { try match($0, in: entry.model?.tasks, what: "task") }
        if let modelTask, modelTask.template != task.id {
            throw PluginWebBridgeFailure.invalidSelection("The model task \(modelTask.name) does not run through \(task.id).")
        }
        var project = try params.selection("project").map { try match($0, in: entry.model?.projects, what: "project") }
        if project == nil, let modelTask {
            project = entry.model?.projects.first { $0.id == modelTask.projectID }
        }
        let target = try params.selection("target").map { try match($0, in: entry.model?.targets, what: "target") }
        let userArguments = try params.strings("userArguments", count: 64, limit: 4096) ?? []
        if !userArguments.isEmpty, !task.requiresUserArguments {
            throw PluginWebBridgeFailure.invalidSelection("The task \(task.id) takes no arguments.")
        }
        let title = Self.title(modelTask.map { $0.displayName ?? $0.name } ?? task.displayName,
                               entry: entry, project: project, target: target)
        try await consent(title, workspaceURL: workspaceURL, userArguments: userArguments)
        let request = BuildTaskRequest(
            task: task.id,
            project: project.map(BuildSelection.init(project:)),
            target: target.map(BuildSelection.init(target:)),
            modelTask: modelTask.map(BuildSelection.init(task:)),
            userArguments: userArguments
        )
        return try start(build, entry: entry) { build.runTask(entry.id, request: request, title: title) }
    }

    private func runTests(_ params: Parameters, workspaceURL: URL) async throws -> ToolingJSONValue {
        let (build, entry) = try await entry(params)
        guard !entry.declaration.testScopes.isEmpty else {
            throw PluginWebBridgeFailure.unavailable("\(entry.instance.displayName) declares no tests.")
        }
        let project = try params.selection("project").map { try match($0, in: entry.model?.projects, what: "project") }
        let target = try params.selection("target").map { try match($0, in: entry.model?.targets, what: "target") }
        let request = BuildTestRequest(
            project: project.map(BuildSelection.init(project:)),
            target: target.map(BuildSelection.init(target:)),
            suite: try params.optionalString("suite", limit: 1024),
            testCase: try params.optionalString("case", limit: 1024),
            projects: entry.model?.projects.map(\.path) ?? []
        )
        let title = Self.title(String(localized: "Tests"), entry: entry, project: project, target: target)
        try await consent(title, workspaceURL: workspaceURL)
        return try start(build, entry: entry) { build.runTests(entry.id, request: request, title: title) }
    }

    /// Starts and tracks a page's run without replacing work from another caller.
    private func start(_ build: any PluginWebBuildAccess, entry: BuildSystemEntry, _ run: () -> UUID?) throws -> ToolingJSONValue {
        // Consent can suspend while a native control or another page starts a
        // run. Check on the main actor immediately before the synchronous start,
        // which would otherwise cancel that run and clear its output.
        guard build.currentRunID == nil else {
            throw PluginWebBridgeFailure.unavailable("Another task or test is running. Stop it before starting a run from this page.")
        }
        guard let serviceRunID = run() else {
            throw PluginWebBridgeFailure.unavailable("\(entry.instance.displayName) could not start.")
        }
        let id = serviceRunID.uuidString.lowercased()
        // Finished IDs remain cancellable as no-ops only for a bounded history.
        // Never retain an unbounded record for a long-lived plugin page.
        if runs.count >= 256 { runs = runs.filter { !$0.value.isFinished } }
        runs[id] = Run(serviceRunID: serviceRunID, entryID: entry.id)
        host?.pluginWebShowBuildOutput()
        scheduleCheck()
        return .object(["run": .string(id)])
    }

    private func dependencies(_ params: Parameters, workspaceURL: URL) async throws -> ToolingJSONValue {
        let (build, entry) = try await entry(params)
        guard !entry.declaration.dependencyScopes.isEmpty else {
            throw PluginWebBridgeFailure.unavailable("\(entry.instance.displayName) declares no dependencies.")
        }
        let project = try params.selection("project").map { try match($0, in: entry.model?.projects, what: "project") }
        let key = project?.path ?? entry.instance.root
        if case .loaded(let tree)? = entry.dependencies[key] { return Self.json(tree) }
        if entry.dependencies[key] != .loading {
            let name = project.map { $0.displayName ?? $0.name } ?? entry.instance.displayName
            try await consent(String(localized: "Load the dependencies of \(name)"), workspaceURL: workspaceURL)
            build.loadDependencies(entry.id, project: project)
        }
        let entryID = entry.id
        let completed = await wait { [weak build] in
            guard let current = build?.entries.first(where: { $0.id == entryID }) else { return true }
            return current.dependencies[key] != .loading
        }
        _ = try currentWorkspace()
        guard completed else { throw PluginWebBridgeFailure.unavailable("Loading the dependencies timed out.") }
        switch build.entries.first(where: { $0.id == entryID })?.dependencies[key] {
        case .loaded(let tree)?: return Self.json(tree)
        case .failed(let message)?: throw PluginWebBridgeFailure.unavailable(message)
        default: throw PluginWebBridgeFailure.unavailable("Loading the dependencies stopped.")
        }
    }

    private func setOptions(_ params: Parameters) async throws -> ToolingJSONValue {
        let (build, entry) = try await entry(params)
        guard case .object(let values)? = params.values["values"], values.count <= 64 else {
            throw PluginWebBridgeFailure.invalidRequest("values is an object of at most 64 option values.")
        }
        let declared = Set(entry.options.map(\.id))
        if let unknown = values.keys.sorted().first(where: { !declared.contains($0) }) {
            throw PluginWebBridgeFailure.invalidRequest("\(entry.instance.displayName) has no option \(unknown).")
        }
        guard (try JSONEncoder().encode(ToolingJSONValue.object(values))).count <= Self.stateLimit else {
            throw PluginWebBridgeFailure.invalidRequest("The option values are larger than 64 KiB.")
        }
        for (id, value) in values.sorted(by: { $0.key < $1.key }) {
            build.setOption(entry.id, optionID: id, value: value == .null ? nil : value)
        }
        let options = build.entries.first { $0.id == entry.id }?.options ?? entry.options
        return .object(["options": Self.storedOptions(options)])
    }

    /// Resolves `instance` to one of this plugin's detected instances.
    private func entry(_ params: Parameters) async throws -> (any PluginWebBuildAccess, BuildSystemEntry) {
        let id = try params.string("instance", limit: 1024)
        guard !window.buildSystemIDs.isEmpty else {
            throw PluginWebBridgeFailure.forbidden("\(window.pluginName) declares no build system.")
        }
        guard let build = try await buildAccess() else {
            throw PluginWebBridgeFailure.unavailable("Build systems are unavailable.")
        }
        if build.isDetecting {
            let completed = await wait { [weak build] in build?.isDetecting != true }
            _ = try currentWorkspace()
            guard completed else { throw PluginWebBridgeFailure.unavailable("Detecting build systems timed out.") }
        }
        guard let entry = build.entries.first(where: { $0.id == id }) else {
            throw PluginWebBridgeFailure.invalidRequest("No build-system instance \(id) is detected in this workspace.")
        }
        guard entry.instance.pluginID == window.pluginID, window.buildSystemIDs.contains(entry.instance.buildSystemID) else {
            throw PluginWebBridgeFailure.forbidden("The instance \(id) belongs to another plugin.")
        }
        return (build, entry)
    }

    private func buildAccess() async throws -> (any PluginWebBuildAccess)? {
        guard let host else { throw PluginWebBridgeFailure.forbidden("The host window was closed.") }
        let build = await host.pluginWebBuildSystems(activate: true)
        // Activation can suspend while the user closes or replaces the workspace.
        _ = try currentWorkspace()
        guard let build else { return nil }
        if self.build !== build { observe(build) }
        return build
    }

    private func observe(_ build: any PluginWebBuildAccess) {
        self.build = build
        observations = [
            build.changes.sink { [weak self] in self?.scheduleCheck() },
            build.runEnded.sink { [weak self] ended in self?.runDidEnd(ended) }
        ]
        scheduleCheck()
    }

    // MARK: Plugin functions

    /// Functions are reached through one of this plugin's own instances, so
    /// a page can call only its plugin's provider process; Core checks the
    /// process owner again.
    private func listFunctions(_ params: Parameters, workspaceURL: URL) async throws -> ToolingJSONValue {
        let (build, entry) = try await entry(params)
        try await consent(String(localized: "Start the \(entry.instance.displayName) provider"), workspaceURL: workspaceURL)
        let functions = try await functionOutcome { try await build.pluginFunctions(entry.id) }
        _ = try currentWorkspace()
        return .object(["functions": .array(functions.map(ToolingJSONValue.string))])
    }

    private func invokeFunction(_ params: Parameters, workspaceURL: URL) async throws -> ToolingJSONValue {
        let (build, entry) = try await entry(params)
        let functionID = try params.string("function", limit: 128)
        let input = params.values["params"] ?? .object([:])
        guard case .object = input else {
            throw PluginWebBridgeFailure.invalidRequest("params must be an object.")
        }
        let pageCall = try params.optionalString("call", limit: 128)
        if let pageCall, usedCallIDs.contains(pageCall) {
            throw PluginWebBridgeFailure.invalidRequest("The call ID \(pageCall) was already used.")
        }
        guard functionCalls.count < Self.functionCallLimit else {
            throw PluginWebBridgeFailure.unavailable("This page already runs \(Self.functionCallLimit) function calls.")
        }
        // Reserve the ID and a slot before consent suspends, so concurrent
        // requests count against the limit and `functions.cancel` reaches it.
        let call = pageCall ?? UUID().uuidString.lowercased()
        let reservation = FunctionCall()
        functionCalls[call] = reservation
        if let pageCall { usedCallIDs.insert(pageCall) }
        defer { if functionCalls[call] === reservation { functionCalls[call] = nil } }
        try await consent(String(localized: "Run \(functionID) of \(entry.instance.displayName)"), workspaceURL: workspaceURL)
        guard !reservation.isCancelled else {
            throw PluginWebBridgeFailure(code: "requestCancelled", message: "The function call was cancelled.")
        }
        let entryID = entry.id
        let timeout = requestTimeout
        let task = Task { @MainActor [weak self, weak reservation] in
            try await build.invokePluginFunction(
                entryID, functionID: functionID, params: input, timeout: timeout
            ) { progress in
                guard let self, let pageCall, let reservation, self.functionCalls[pageCall] === reservation else { return }
                var payload: [String: ToolingJSONValue] = [
                    "call": .string(pageCall), "instance": .string(entryID), "function": .string(functionID)
                ]
                if let message = progress.message { payload["message"] = .string(message) }
                if let percentage = progress.percentage { payload["percentage"] = .integer(percentage) }
                self.emit?("functions.progress", .object(payload))
            }
        }
        reservation.task = task
        let value = try await withTaskCancellationHandler {
            try await functionOutcome { try await task.value }
        } onCancel: {
            task.cancel()
        }
        _ = try currentWorkspace()
        return .object(["value": value])
    }

    /// Passes Core's outcome codes through unchanged, so a page sees the same
    /// `plugin.function.*`, `requestCancelled`, and `requestTimeout` codes on
    /// every host.
    private func functionOutcome<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let failure as PluginFunctionFailure {
            throw PluginWebBridgeFailure(code: failure.code, message: failure.message, pluginErrorCode: failure.pluginErrorCode)
        } catch is CancellationError {
            throw PluginWebBridgeFailure(code: "requestCancelled", message: "The function call was cancelled.")
        } catch let failure as PluginWebBridgeFailure {
            throw failure
        } catch {
            throw PluginWebBridgeFailure(code: "plugin.function.unavailable", message: error.localizedDescription)
        }
    }

    // MARK: Events

    private func runDidEnd(_ ended: BuildRunEnd) {
        guard (try? currentWorkspace()) != nil else { close(); return }
        guard let (id, run) = runs.first(where: { $0.value.serviceRunID == ended.runID }), !run.isFinished else { return }
        runs[id]?.isFinished = true
        let state: String = switch ended.state {
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled, .idle, .running: "cancelled"
        }
        var payload: [String: ToolingJSONValue] = ["run": .string(id), "instance": .string(run.entryID), "state": .string(state)]
        if let exitCode = ended.exitCode { payload["exitCode"] = .integer(Int(exitCode)) }
        emit?("build.runChanged", .object(payload))
    }

    /// `objectWillChange` fires before the change is stored, so the page is
    /// told in a later main-actor job, once per burst of changes.
    private func scheduleCheck() {
        guard !isCheckScheduled, !isClosed else { return }
        isCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCheckScheduled = false
            self.check()
        }
    }

    private func check() {
        guard !isClosed, let build else { return }
        guard (try? currentWorkspace()) != nil else { close(); return }
        for (id, run) in runs where !run.isAnnounced && !run.isFinished {
            runs[id]?.isAnnounced = true
            emit?("build.runChanged", .object([
                "run": .string(id), "instance": .string(run.entryID), "state": .string("running")
            ]))
        }
        let instances = instancesJSON(build)
        if instances != lastInstances {
            let isFirst = lastInstances == nil
            lastInstances = instances
            if !isFirst { emit?("build.instancesChanged", .object(["instances": instances])) }
        }
        let ready = waiters.filter { $0.isSatisfied() }.map(\.id)
        ready.forEach { finishWaiter($0, completed: true) }
    }

    /// Event-driven waits end on completion, cancellation, page close, or the
    /// same bounded model budget used by the build service.
    private func wait(until isSatisfied: @escaping @MainActor () -> Bool) async -> Bool {
        if isSatisfied() { return true }
        guard !isClosed, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = Task { @MainActor [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    self?.finishWaiter(id, completed: false)
                }
                waiters.append(Waiter(id: id, isSatisfied: isSatisfied, continuation: continuation, timeout: timeout))
                scheduleCheck()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finishWaiter(id, completed: false) }
        }
    }

    private func finishWaiter(_ id: UUID, completed: Bool) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: completed)
    }

    private func instancesJSON(_ build: any PluginWebBuildAccess) -> ToolingJSONValue {
        .array(build.entries.filter {
            $0.instance.pluginID == window.pluginID && window.buildSystemIDs.contains($0.instance.buildSystemID)
        }.map(Self.json))
    }

    // MARK: Workspace and consent

    private func currentWorkspace() throws -> URL {
        guard !isClosed, let workspaceURL, host?.pluginWebWorkspaceURL?.standardizedFileURL == workspaceURL else {
            throw PluginWebBridgeFailure.forbidden("The page belongs to a workspace that is no longer open.")
        }
        return workspaceURL
    }

    private func consent(_ action: String, workspaceURL: URL, userArguments: [String] = []) async throws {
        let request = PluginWebProcessConsent(
            pluginID: window.pluginID, pluginName: window.pluginName, workspaceURL: workspaceURL,
            action: action, userArguments: userArguments
        )
        guard let host, await host.pluginWebConfirmProcessStart(request), !isClosed else {
            throw PluginWebBridgeFailure.forbidden("Running build tools from this page was not allowed.")
        }
        _ = try currentWorkspace()
    }

    private func openFile(_ params: Parameters, workspaceURL: URL) throws -> ToolingJSONValue {
        let path = try params.string("path", limit: 4096)
        let line = try params.integer("line")
        let column = try params.integer("column")
        let root = workspaceURL.resolvingSymlinksInPath().path
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspaceURL.appendingPathComponent(path))
            .standardizedFileURL
        guard !path.contains("\0"), !path.split(separator: "/").contains(".."),
              url.resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
            throw PluginWebBridgeFailure.forbidden("\(path) is outside the workspace.")
        }
        guard host?.pluginWebOpenFile(url, line: line, column: column) == true else {
            throw PluginWebBridgeFailure.invalidRequest("The workspace has no file \(path).")
        }
        return .object([:])
    }

    private func match<Item: PluginWebSelectable>(_ selection: Parameters.Selection, in items: [Item]?, what: String) throws -> Item {
        guard let items else {
            throw PluginWebBridgeFailure.invalidSelection("Load the model before selecting a \(what).")
        }
        let candidates = items.filter {
            (selection.path == nil || $0.selectionPath == selection.path)
                && (selection.name == nil || $0.name == selection.name)
                && (selection.tags == nil || Set($0.selectionTags) == selection.tags)
        }
        guard let item = candidates.first else {
            throw PluginWebBridgeFailure.invalidSelection("The model has no such \(what).")
        }
        guard candidates.count == 1 else {
            throw PluginWebBridgeFailure.invalidSelection("The selection matches more than one \(what) in the model.")
        }
        return item
    }

    private static func title(_ name: String, entry: BuildSystemEntry, project: BuildModel.Project?, target: BuildModel.Target?) -> String {
        let scope = target?.name ?? project.map { $0.displayName ?? $0.name } ?? entry.instance.displayName
        return "\(scope): \(name)"
    }
}

/// Model entities a page selects by name, workspace-relative path, and target tags.
protocol PluginWebSelectable {
    var name: String { get }
    var selectionPath: String { get }
    var selectionTags: [String] { get }
}

extension PluginWebSelectable { var selectionTags: [String] { [] } }
extension BuildModel.Project: PluginWebSelectable { var selectionPath: String { path } }
extension BuildModel.Target: PluginWebSelectable {
    var selectionPath: String { path }
    var selectionTags: [String] { tags }
}
extension BuildModel.Task: PluginWebSelectable { var selectionPath: String { path } }

/// Request parameters. Unknown fields are refused so a misspelt field is
/// not silently ignored.
private struct Parameters {
    struct Selection {
        let name: String?
        let path: String?
        let tags: Set<String>?
    }

    let values: [String: ToolingJSONValue]

    init(_ params: ToolingJSONValue, allowed: Set<String>) throws {
        switch params {
        case .null: values = [:]
        case .object(let values): self.values = values
        default: throw PluginWebBridgeFailure.invalidRequest("The parameters must be an object.")
        }
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw PluginWebBridgeFailure.invalidRequest("Unknown parameter \(unknown).")
        }
    }

    func string(_ key: String, limit: Int = 1024) throws -> String {
        guard let value = try optionalString(key, limit: limit) else {
            throw PluginWebBridgeFailure.invalidRequest("\(key) is required.")
        }
        return value
    }

    func optionalString(_ key: String, limit: Int) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)? where !value.isEmpty && value.count <= limit && !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }): return value
        default: throw PluginWebBridgeFailure.invalidRequest("\(key) must be a string of 1 to \(limit) characters.")
        }
    }

    func integer(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .integer(let value)? where (1...10_000_000).contains(value): return value
        default: throw PluginWebBridgeFailure.invalidRequest("\(key) must be a positive integer.")
        }
    }

    func strings(_ key: String, count: Int, limit: Int) throws -> [String]? {
        switch values[key] {
        case nil, .null?: return nil
        case .array(let items)? where items.count <= count:
            return try items.map { item in
                guard case .string(let value) = item, value.count <= limit, !value.contains("\0") else {
                    throw PluginWebBridgeFailure.invalidRequest("\(key) must be at most \(count) strings.")
                }
                return value
            }
        default: throw PluginWebBridgeFailure.invalidRequest("\(key) must be at most \(count) strings.")
        }
    }

    /// `{ name?, path?, tags?, execution?, properties? }` as `build.taskPlan`
    /// takes it. Names, paths, and validated tag sets identify one model entity;
    /// the host rebuilds all plan values from it, including tags and properties.
    func selection(_ key: String) throws -> Selection? {
        switch values[key] {
        case nil, .null?: return nil
        case .object(let fields)?:
            let selection = try Parameters(.object(fields), allowed: ["name", "path", "tags", "execution", "properties"])
            let name = try selection.optionalString("name", limit: 1024)
            let path = try selection.optionalString("path", limit: 4096)
            let tags = try selection.strings("tags", count: 64, limit: 64)
            if let tags, tags.contains(where: { $0.isEmpty || $0.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) }) {
                throw PluginWebBridgeFailure.invalidRequest("\(key).tags must contain non-empty printable strings.")
            }
            guard name != nil || path != nil else {
                throw PluginWebBridgeFailure.invalidRequest("\(key) needs a name or a path.")
            }
            if let path, path.hasPrefix("/") || path.contains("\\") || path.split(separator: "/").contains("..") {
                throw PluginWebBridgeFailure.forbidden("\(path) is outside the workspace.")
            }
            return Selection(name: name, path: path, tags: tags.map { Set($0) })
        default: throw PluginWebBridgeFailure.invalidRequest("\(key) must be a selection object.")
        }
    }
}

// MARK: JSON

/// The bridge sends Core's decoded shapes back as JSON.
extension PluginWebBridge {
    static func json(_ entry: BuildSystemEntry) -> ToolingJSONValue {
        var object: [String: ToolingJSONValue] = [
            "id": .string(entry.id),
            "buildSystemID": .string(entry.instance.buildSystemID),
            "root": .string(entry.instance.root),
            "options": storedOptions(entry.options)
        ]
        switch entry.modelState {
        case .notLoaded: object["state"] = .string("notLoaded")
        case .loading: object["state"] = .string("loading")
        case .loaded: object["state"] = .string("loaded")
        case .failed(let message):
            object["state"] = .string("failed")
            object["error"] = .object(["message": .string(message)])
        }
        if let model = entry.model { object["model"] = json(model) }
        return .object(object)
    }

    static func json(_ model: BuildModel) -> ToolingJSONValue {
        .object([
            "projects": .array(model.projects.map { project in
                .object(compact([
                    "id": .string(project.id), "path": .string(project.path), "name": .string(project.name),
                    "displayName": project.displayName.map(ToolingJSONValue.string),
                    "parentID": project.parentID.map(ToolingJSONValue.string),
                    "properties": strings(project.properties)
                ]))
            }),
            "targets": .array(model.targets.map { target in
                .object([
                    "id": .string(target.id), "projectID": .string(target.projectID), "name": .string(target.name),
                    "path": .string(target.path), "tags": .array(target.tags.map(ToolingJSONValue.string)),
                    "properties": strings(target.properties)
                ])
            }),
            "tasks": .array(model.tasks.map { task in
                .object(compact([
                    "id": .string(task.id), "projectID": .string(task.projectID), "name": .string(task.name),
                    "path": .string(task.path), "displayName": task.displayName.map(ToolingJSONValue.string),
                    "description": task.description.map(ToolingJSONValue.string),
                    "template": .string(task.template), "group": .string(task.group.rawValue),
                    "execution": .string(task.execution.rawValue),
                    "category": task.category.isEmpty ? nil : .array(task.category.map(ToolingJSONValue.string)),
                    "properties": strings(task.properties)
                ]))
            }),
            "run": .array(model.run),
            "contentRoots": .array(model.contentRoots.map { root in
                .object(["projectID": .string(root.projectID), "path": .string(root.path), "kind": .string(root.kind)])
            }),
            "optionValues": .object(model.optionValues.mapValues { .array($0.map(ToolingJSONValue.string)) }),
            "truncated": .bool(model.truncated)
        ])
    }

    /// The values the user stored, as Core accepted them; options left at
    /// their default are absent.
    static func storedOptions(_ options: [BuildResolvedOption]) -> ToolingJSONValue {
        .object(Dictionary(uniqueKeysWithValues: options.filter { $0.source == "user" }.map { ($0.id, $0.value) }))
    }

    static func json(_ tree: BuildDependencyTree) -> ToolingJSONValue {
        func encode(_ node: BuildDependencyNode) -> ToolingJSONValue {
            .object(compact([
                "name": .string(node.name), "group": node.group.map(ToolingJSONValue.string),
                "version": node.version.map(ToolingJSONValue.string), "scope": node.scope.map(ToolingJSONValue.string),
                "properties": strings(node.properties), "children": .array(node.children.map(encode))
            ]))
        }
        return .object(["dependencies": .array(tree.dependencies.map(encode)), "truncated": .bool(tree.truncated)])
    }

    private static func strings(_ values: [String: String]) -> ToolingJSONValue {
        .object(values.mapValues(ToolingJSONValue.string))
    }

    private static func compact(_ values: [String: ToolingJSONValue?]) -> [String: ToolingJSONValue] {
        values.compactMapValues { $0 }
    }
}
