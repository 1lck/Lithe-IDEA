import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Where a window shows the runs and debug sessions a plugin backend started. The window
/// owns the process, the console and the debugger; the service only decides what to start.
@MainActor
protocol PluginRunWindowPort: AnyObject {
    /// Shows `launch` in the Run window and starts it. `debug` asks for a debugger that attaches
    /// to the process once it listens. `onEnd` runs once when the process ends, however it ends.
    func hostStartPluginRun(_ launch: PluginRunLaunch, debug: PluginRunStart.Debug?,
                            rerun: (@MainActor @Sendable () -> Void)?,
                            onEnd: @escaping @MainActor @Sendable (PluginRunEnd) -> Void) async throws
    func hostStopPluginRun(runID: String)
    /// Starts a debug session on `start.adapterID` and returns its ID. `onEnd` gets the ID when
    /// the session is gone.
    func hostStartPluginDebugSession(_ start: PluginDebugStart,
                                     onEnd: @escaping @MainActor @Sendable (String) -> Void) async throws -> String
    func hostStopPluginDebugSession(_ sessionID: String)
    /// Tells the user about a failure no request is left to answer, such as a backend that
    /// could not prepare the run again.
    func hostReportPluginRunProblem(_ message: String)
}

/// What the run service needs from the plugin backends: their manifests and packages, the
/// functions it calls to run again, and the way to tell a backend that a run ended.
@MainActor
protocol PluginRunBackendLink: PluginBackendRequesting {
    /// The normalized manifest of the installed plugin; nil when it is not installed.
    func manifest(ofPlugin pluginID: String) -> Data?
    /// Where the installed plugin package lives.
    func packageURL(ofPlugin pluginID: String) -> URL?
    /// Sends `lithe/host/run/didExit` to the backend session that saw the run begin. A backend
    /// that is gone, or started again since, hears nothing.
    func notifyRunDidExit(pluginID: String, sessionID: String, params: ToolingJSONValue)
}

/// `lithe/host/run/start`, `run/stop` and `debug/start`: a backend asks the host to run a
/// process in the Run window, or to start a debug session on one of the plugin's adapters.
///
/// The host owns what it starts. Rust Core decides whether the request is well formed and what
/// the plugin may name; this service resolves tools, writes temporary files, hands the process
/// to the window and reports the end. A process keeps running when its plugin is disabled or its
/// backend exits: the backend then simply hears nothing more.
@MainActor
final class PluginRunHostService: PluginHostServiceHandling {
    let service = "run"
    let methods: Set<String> = ["lithe/host/run/start", "lithe/host/run/stop", "lithe/host/debug/start"]

    /// A run that has started and not yet ended.
    private struct Run {
        let pluginID: String
        /// The backend session that saw the run begin; only it hears `run/didExit`.
        let sessionID: String
        /// Holds the run's temporary files; removed when the run ends.
        let temporaryDirectory: URL?
        weak var window: (any PluginRunWindowPort)?
    }

    private struct DebugSession {
        let pluginID: String
        weak var window: (any PluginRunWindowPort)?
    }

    private let contexts: PluginWorkspaceContexts
    private let decoder: any PluginRunStartDecoding
    private let tools: any DefinedToolchainResolving & DefinedToolLaunching
    private let fileStorage: any FileStorage
    /// The environment children of the application get: the login shell's, with the runtime's changes.
    private let baseEnvironment: @MainActor () -> [String: String]
    weak var backends: (any PluginRunBackendLink)?
    private var runs: [String: Run] = [:]
    private var debugSessions: [String: DebugSession] = [:]

    init(contexts: PluginWorkspaceContexts, decoder: any PluginRunStartDecoding,
         tools: any DefinedToolchainResolving & DefinedToolLaunching, fileStorage: any FileStorage,
         baseEnvironment: @escaping @MainActor () -> [String: String]) {
        self.contexts = contexts
        self.decoder = decoder
        self.tools = tools
        self.fileStorage = fileStorage
        self.baseEnvironment = baseEnvironment
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            switch call.request.method {
            case "lithe/host/run/start": return .success(try await startRun(call))
            case "lithe/host/debug/start": return .success(try await startDebug(call))
            default: return .success(try stop(call))
            }
        } catch {
            var failure = Self.failure(error)
            failure.logError = error
            return .failure(failure)
        }
    }

    // MARK: run/start

    private func startRun(_ call: PluginHostCall) async throws -> ToolingJSONValue {
        let scope = try PluginHostAPIContext(call, contexts: contexts)
        guard let window = scope.window as? any PluginRunWindowPort else { throw Self.windowCannotRun }
        let runID = UUID().uuidString
        let directory = fileStorage.temporaryDirectory().appendingPathComponent("lithe-plugin-run-\(runID)", isDirectory: true)
        let start = try decoder.decodeRunStart(manifest: try manifest(of: call.pluginID), workspaceRoot: scope.snapshot.workspaceURL,
                                               temporaryDirectory: directory, params: .object(call.params))
        // The adapter that starts the process itself is not implemented yet; say so before anything runs.
        if start.debug?.target == .launch {
            throw PluginHostServiceError(.unsupportedOption, L10n.string("The host does not support the requested option yet."),
                                         details: ["option": .string("debug.target")])
        }
        let launch = try await resolveLaunch(start, runID: runID, pluginID: call.pluginID, workspace: scope.snapshot.workspaceURL)
        try Task.checkCancellation()
        let temporaryDirectory = try writeTemporaryFiles(of: start, to: directory)
        runs[runID] = Run(pluginID: call.pluginID, sessionID: call.sessionID, temporaryDirectory: temporaryDirectory, window: window)
        do {
            try await window.hostStartPluginRun(launch, debug: start.debug,
                                                rerun: start.rerun.map { rerunAction($0, pluginID: call.pluginID, window: window) },
                                                onEnd: { [weak self] end in self?.runEnded(end) })
            // A cancelled request means the backend no longer waits for the run ID: that is a Stop.
            try Task.checkCancellation()
        } catch {
            window.hostStopPluginRun(runID: runID)
            forgetRun(runID)
            throw error
        }
        return .object(["runID": .string(runID)])
    }

    /// The program, arguments, directory and environment of the process, with the tool resolved.
    private func resolveLaunch(_ start: PluginRunStart, runID: String, pluginID: String, workspace: URL) async throws -> PluginRunLaunch {
        let directory = start.workingDirectory == "."
            ? workspace : workspace.appendingPathComponent(start.workingDirectory, isDirectory: true)
        try Self.requireInside(directory, of: workspace)
        var environment = baseEnvironment()
        let program: String
        var arguments = start.arguments
        switch start.executable {
        case .tool(let tool):
            let selected = try await select(tool, start: start, workspace: workspace, environment: environment)
            let expanded = try expand(selected, tool: tool, arguments: arguments)
            program = expanded.executable
            arguments = expanded.arguments
            environment = selected.environment
        case .packaged(let path):
            program = try packagedExecutable(path, pluginID: pluginID).path
        }
        // What the plugin names explicitly wins over what the tool exports.
        environment.merge(start.environment) { _, explicit in explicit }
        return PluginRunLaunch(runID: runID, title: start.label, executableURL: URL(fileURLWithPath: program),
                               arguments: arguments, workingDirectory: directory, environment: environment)
    }

    /// The installation the user's layers choose for `tool`. Project code is allowed, as for any Run.
    ///
    /// Core expands the definition's `launch` template afterwards (`expand`), so the tool is
    /// resolved as an installation: a template with `${runtimeArguments}` or wrapper flags is
    /// as valid here as the bare `["${executable}", "${arguments}"]` a direct launch needs.
    private func select(_ tool: String, start: PluginRunStart, workspace: URL,
                        environment: [String: String]) async throws -> ResolvedDefinedToolchain {
        do {
            if let selected = try await tools.resolve(tool: tool, directory: start.workingDirectory, workspace: workspace,
                                                      environment: environment, minimumVersion: nil, projectCodeAllowed: true,
                                                      fixed: nil, use: .installation, consumerID: nil) {
                return selected
            }
        } catch is BuildToolResolutionError {
            // The user's choice names an installation that cannot run.
            throw Self.toolUnresolved(tool, reason: "unusable")
        }
        throw Self.toolUnresolved(tool, reason: "notFound")
    }

    /// Core expands the definition's launch template; a tool that cannot carry these arguments is unusable.
    private func expand(_ selected: ResolvedDefinedToolchain, tool: String, arguments: [String]) throws -> DefinedToolLaunch {
        do {
            return try tools.launch(of: selected, tool: tool, arguments: arguments)
        } catch is DefinedToolLaunchRejection {
            throw Self.toolUnresolved(tool, reason: "unusable")
        }
    }

    private func packagedExecutable(_ path: String, pluginID: String) throws -> URL {
        guard let package = backends?.packageURL(ofPlugin: pluginID) else { throw Self.backendGone }
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        // Core refused `..`; a link inside the package must not lead out of it either.
        guard file.path.hasPrefix(root.path + "/"), fileStorage.isExecutable(at: file) else {
            throw PluginHostServiceError(.notFound, L10n.string("The plugin package has no such executable file."))
        }
        return file
    }

    /// Creates the directory only when the run has files to put in it.
    private func writeTemporaryFiles(of start: PluginRunStart, to directory: URL) throws -> URL? {
        guard !start.temporaryFiles.isEmpty else { return nil }
        do {
            try fileStorage.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in start.temporaryFiles {
                try fileStorage.writeData(Data(file.contents.utf8), to: URL(fileURLWithPath: file.path), options: [.atomic])
            }
        } catch {
            removeTemporaryDirectory(directory)
            throw error
        }
        return directory
    }

    /// Run again: the backend prepares the restart and answers with a new `run/start`.
    private func rerunAction(_ rerun: PluginRunStart.Rerun, pluginID: String,
                             window: any PluginRunWindowPort) -> @MainActor @Sendable () -> Void {
        return { [weak self, weak window] in
            guard let self, let window, let backends = self.backends,
                  let context = self.contexts.context(ownedBy: window)?.reference else { return }
            Task { @MainActor in
                do {
                    _ = try await backends.invokePluginFunction(rerun.function, params: rerun.data, ofPlugin: pluginID,
                                                                context: context, timeout: .seconds(30), progress: { _ in })
                } catch {
                    guard !(error is CancellationError) else { return }
                    window.hostReportPluginRunProblem(error.localizedDescription)
                }
            }
        }
    }

    // MARK: End of a run

    /// Reports the end to the backend that saw the run begin, and removes what the run left behind.
    private func runEnded(_ end: PluginRunEnd) {
        guard let run = runs[end.runID] else { return }
        forgetRun(end.runID)
        var params: [String: ToolingJSONValue] = ["runID": .string(end.runID)]
        if let code = end.exitCode { params["exitCode"] = .integer(Int(code)) }
        backends?.notifyRunDidExit(pluginID: run.pluginID, sessionID: run.sessionID, params: .object(params))
    }

    private func forgetRun(_ runID: String) {
        guard let run = runs.removeValue(forKey: runID) else { return }
        if let directory = run.temporaryDirectory { removeTemporaryDirectory(directory) }
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        // log-exempt: 临时目录清理失败不影响运行结果，系统会回收临时目录
        try? fileStorage.removeItem(at: directory)
    }

    // MARK: debug/start

    private func startDebug(_ call: PluginHostCall) async throws -> ToolingJSONValue {
        let scope = try PluginHostAPIContext(call, contexts: contexts)
        guard let window = scope.window as? any PluginRunWindowPort else { throw Self.windowCannotRun }
        let start = try decoder.decodeDebugStart(manifest: try manifest(of: call.pluginID), params: .object(call.params))
        let sessionID = try await window.hostStartPluginDebugSession(start, onEnd: { [weak self] id in
            self?.debugSessions[id] = nil
        })
        debugSessions[sessionID] = DebugSession(pluginID: call.pluginID, window: window)
        if Task.isCancelled {
            window.hostStopPluginDebugSession(sessionID)
            throw CancellationError()
        }
        return .object(["sessionID": .string(sessionID)])
    }

    // MARK: run/stop

    /// Stops a run or a debug session of the calling plugin. It names no context, so it still
    /// works after the context it started in has closed. Anything else is ignored.
    private func stop(_ call: PluginHostCall) throws -> ToolingJSONValue {
        let args = try PluginHostArguments(call.params, allowed: ["runID", "sessionID"])
        switch (try args.optionalString("runID"), try args.optionalString("sessionID")) {
        case (let runID?, nil):
            if let run = runs[runID], run.pluginID == call.pluginID { run.window?.hostStopPluginRun(runID: runID) }
        case (nil, let sessionID?):
            if let session = debugSessions[sessionID], session.pluginID == call.pluginID {
                session.window?.hostStopPluginDebugSession(sessionID)
            }
        default:
            throw PluginHostArguments.invalid
        }
        return .null
    }

    // MARK: Shared

    private func manifest(of pluginID: String) throws -> Data {
        guard let manifest = backends?.manifest(ofPlugin: pluginID) else { throw Self.backendGone }
        return manifest
    }

    /// A directory the plugin named must still be inside the workspace once links are resolved.
    private static func requireInside(_ directory: URL, of workspace: URL) throws {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw PluginHostError.outsideWorkspace
        }
    }

    private static var backendGone: PluginHostServiceError {
        PluginHostServiceError(.backendExited, L10n.string("The plugin backend is no longer running."))
    }

    private static var windowCannotRun: PluginHostServiceError {
        PluginHostServiceError(.unavailable, L10n.string("This window cannot start runs for plugins."))
    }

    private static func toolUnresolved(_ tool: String, reason: String) -> PluginHostServiceError {
        PluginHostServiceError(.toolUnresolved, L10n.string("No installed tool matches the one the plugin asked to run."),
                               details: ["tool": .string(tool), "reason": .string(reason)])
    }

    /// Core's refusal reaches the backend as the `plugin.host` error of its kind, with Core's own
    /// code and field in the details so the backend can tell which part of the request was wrong.
    private static func failure(_ error: Error) -> PluginHostServiceError {
        guard let rejection = error as? DeclarativePluginRejection else { return PluginHostAPIValues.failure(error) }
        var details: [String: ToolingJSONValue] = ["code": .string(rejection.code)]
        if let field = rejection.field { details["field"] = .string(field) }
        switch rejection.code {
        case "plugin.debug.unknownAdapter", "plugin.debug.foreignAdapter":
            return PluginHostServiceError(.notFound, L10n.string("The plugin declares no such debug adapter."), details: details)
        case "plugin.debug.limitExceeded":
            return PluginHostServiceError(.limitExceeded, L10n.string("The debug configuration is too large."), details: details)
        default:
            return PluginHostServiceError(.invalidParams, L10n.string("The plugin host request parameters are invalid."), details: details)
        }
    }
}
