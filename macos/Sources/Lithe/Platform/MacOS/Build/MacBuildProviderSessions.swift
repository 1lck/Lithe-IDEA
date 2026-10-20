import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

/// Provider processes of plugin build systems. Each process belongs to one
/// build system of one plugin in one workspace: two plugins never share a
/// process, and every process talks only to the host over its own stdio
/// channel, so no plugin can reach another plugin's provider.
///
/// A process starts on the first request, which only a user action sends,
/// and runs until `retainProviders` drops its target (a workspace switch,
/// project close, module shutdown, or a disabled plugin), or
/// `stopProviders(ofPlugin:)` stops it before its package is replaced or
/// removed. A change of the plugin's
/// settings restarts it on the next request. Its writable state lives
/// in the build system's plugin state directory, never in the app bundle or
/// the plugin package.
@MainActor
final class MacBuildProviderSessions: BuildProviderRequesting {
    struct UnavailableError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The language session manager, when the language module is active. A
    /// provider that shares a language server goes through it.
    var languageSessions: (@MainActor () -> LanguageToolingSessionManager?)?

    private let launchResolver: MacPluginLanguageServerLaunchResolver
    private let tools: any BuildToolResolving
    private let versionChecker: any LanguageServerRuntimeVersionChecking
    private let runtime: any LanguageToolRuntimePort
    private let core: any LanguageServerRuntimeCore
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    /// Ends the processes carrying a backend's token; `immediately` skips the
    /// graceful stop. See `MacPluginBackendProcesses`.
    private let endBackendProcesses: @MainActor (_ token: String, _ immediately: Bool) -> Void
    private let stuckSendGrace: Duration
    private var running: [BuildProviderTarget: Running] = [:]

    /// One process, from its start until it is dropped. `session` is set as
    /// soon as the process is launched, so a drop during initialize stops it.
    private final class Running {
        let id = UUID()
        /// The plugin's setting values the launch was expanded with.
        let settings: [String: ToolingJSONValue]
        var task: Task<LanguageServerRuntimeSession, Error>?
        var session: LanguageServerRuntimeSession?

        init(settings: [String: ToolingJSONValue]) {
            self.settings = settings
        }
    }

    init(
        launchResolver: MacPluginLanguageServerLaunchResolver,
        tools: any BuildToolResolving,
        versionChecker: any LanguageServerRuntimeVersionChecking,
        runtime: any LanguageToolRuntimePort,
        core: any LanguageServerRuntimeCore,
        processRegistry: (any LanguageServerProcessRegistry)?,
        stuckSendGrace: Duration = .seconds(2),
        endBackendProcesses: @escaping @MainActor (_ token: String, _ immediately: Bool) -> Void = { token, immediately in
            MacPluginBackendProcesses.end(
                token: token,
                gracePeriod: immediately ? 0 : TimeInterval(MacProcessSupervisor.storedSettings().gracefulStopSeconds)
            )
        }
    ) {
        self.launchResolver = launchResolver
        self.tools = tools
        self.versionChecker = versionChecker
        self.runtime = runtime
        self.core = core
        self.processRegistry = processRegistry
        self.endBackendProcesses = endBackendProcesses
        self.stuckSendGrace = stuckSendGrace
    }

    func send(
        _ request: BuildProviderRequest,
        to target: BuildProviderTarget,
        timeout: Duration
    ) async throws -> ToolingJSONValue {
        try Task.checkCancellation()
        let seconds = Self.seconds(timeout)
        let settings = launchResolver.settingValues(forPlugin: target.pluginID)
        if let session = try await runningSession(for: target, settings: settings) {
            return try await session.buildRequest(method: request.method, params: request.params, timeout: seconds)
        }
        switch try launchResolver.resolveBuildProvider(
            pluginID: target.pluginID,
            buildSystemID: target.buildSystemID,
            manifest: target.manifest,
            packageURL: target.packageURL,
            workspaceRootURL: target.workspaceURL
        ) {
        case .languageServer(let languageID):
            guard let sessions = languageSessions?() else {
                throw UnavailableError(message: String(
                    localized: "The language server this build system uses is not available. Open a file of the language and try again."
                ))
            }
            return try await sessions.requestBuildProvider(
                languageID: languageID,
                pluginID: target.pluginID,
                rootURL: target.workspaceURL,
                method: request.method,
                params: request.params,
                timeout: seconds
            )
        case .process(let process):
            let session = try await startSession(for: target, process: process)
            try Task.checkCancellation()
            return try await session.buildRequest(method: request.method, params: request.params, timeout: seconds)
        }
    }

    func pluginFunctions(of target: BuildProviderTarget) async throws -> [String] {
        try await functionSession(for: target).functionIDs
    }

    func invokePluginFunction(
        _ functionID: String,
        params: ToolingJSONValue,
        on target: BuildProviderTarget,
        timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        let session = try await functionSession(for: target)
        return try await session.invokeFunction(
            functionID, params: params, timeout: Self.seconds(timeout), progress: progress
        )
    }

    /// The target's own process, started like `send` would. Functions are
    /// served only by a process the plugin owns: a shared language server is
    /// started by the host for every plugin of its language, so it never
    /// serves one plugin's functions.
    private func functionSession(for target: BuildProviderTarget) async throws -> LanguageServerRuntimeSession {
        try Task.checkCancellation()
        let settings = launchResolver.settingValues(forPlugin: target.pluginID)
        if let session = try await runningSession(for: target, settings: settings) { return session }
        switch try launchResolver.resolveBuildProvider(
            pluginID: target.pluginID,
            buildSystemID: target.buildSystemID,
            manifest: target.manifest,
            packageURL: target.packageURL,
            workspaceRootURL: target.workspaceURL
        ) {
        case .languageServer:
            throw PluginFunctionFailure(
                code: "plugin.function.unavailable",
                message: String(localized: "This build system's provider runs in a shared language server, which serves no plugin functions.")
            )
        case .process(let process):
            let session = try await startSession(for: target, process: process)
            try Task.checkCancellation()
            return session
        }
    }

    func retainProviders(_ keep: (BuildProviderTarget) -> Bool) {
        for (target, entry) in running where !keep(target) {
            stop(entry, for: target)
        }
    }

    /// Stops every process of `pluginID`, in every workspace. The plugin
    /// manager calls it before the package is replaced, rolled back, or
    /// uninstalled, so no process keeps running the files it replaces.
    func stopProviders(ofPlugin pluginID: String) {
        retainProviders { $0.pluginID != pluginID }
    }

    private func stop(_ entry: Running, for target: BuildProviderTarget) {
        if running[target] === entry { running[target] = nil }
        entry.task?.cancel()
        entry.session?.stop()
    }

    /// The process already started for `target`; nil when none runs. A
    /// process that exited or crashed is replaced by the next request, and
    /// so is one started with other setting values: its arguments, such as
    /// a heap size, came from the settings it was launched with.
    private func runningSession(
        for target: BuildProviderTarget,
        settings: [String: ToolingJSONValue]
    ) async throws -> LanguageServerRuntimeSession? {
        guard let entry = running[target], let task = entry.task else { return nil }
        if entry.settings != settings {
            stop(entry, for: target)
            return nil
        }
        if let session = entry.session, !session.isRunning {
            running[target] = nil
            return nil
        }
        let session = try await Self.waitForStart(task)
        guard running[target] === entry else { throw CancellationError() }
        return session
    }

    private func startSession(
        for target: BuildProviderTarget,
        process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess
    ) async throws -> LanguageServerRuntimeSession {
        // Another request may have started the process while this one
        // resolved the launch.
        if let session = try await runningSession(for: target, settings: process.settings) { return session }
        try Task.checkCancellation()
        let entry = Running(settings: process.settings)
        running[target] = entry
        // The start is shared by every request that arrives meanwhile, so no
        // single caller's cancellation cancels it; a failed start clears the
        // entry itself.
        let task = Task { @MainActor [weak self] () throws -> LanguageServerRuntimeSession in
            guard let self else { throw CancellationError() }
            do {
                return try await self.launch(process, for: target, entry: entry)
            } catch {
                if self.running[target] === entry { self.running[target] = nil }
                throw error
            }
        }
        entry.task = task
        let session = try await Self.waitForStart(task)
        guard running[target] === entry else { throw CancellationError() }
        return session
    }

    /// Waits for a shared start. A cancelled caller stops waiting at once,
    /// while the start goes on for the other callers and the next request.
    private static func waitForStart(
        _ task: Task<LanguageServerRuntimeSession, Error>
    ) async throws -> LanguageServerRuntimeSession {
        let waiter = StartWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.wait(with: continuation)
                if Task.isCancelled {
                    waiter.finish(.failure(CancellationError()))
                    return
                }
                Task { @MainActor in waiter.finish(await task.result) }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }

    @MainActor
    private final class StartWaiter {
        private var continuation: CheckedContinuation<LanguageServerRuntimeSession, Error>?

        func wait(with continuation: CheckedContinuation<LanguageServerRuntimeSession, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<LanguageServerRuntimeSession, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func launch(
        _ process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess,
        for target: BuildProviderTarget,
        entry: Running
    ) async throws -> LanguageServerRuntimeSession {
        var (executableURL, environment) = try await resolveExecutable(process, workspaceURL: target.workspaceURL)
        try Task.checkCancellation()
        guard running[target] === entry else { throw CancellationError() }
        // Every process the backend starts inherits this token, so what it
        // leaves behind can be ended when the backend is gone.
        let backendToken = UUID().uuidString
        environment.merge(MacPluginBackendProcesses.environment(token: backendToken)) { _, token in token }
        let session = LanguageServerRuntimeSession(
            providerID: "buildProvider:\(target.pluginID):\(target.buildSystemID)",
            executableURL: executableURL,
            arguments: process.arguments,
            environment: environment,
            initializationOptions: process.initializationOptions,
            initializeTimeout: 60,
            core: core,
            processRegistry: processRegistry,
            moduleID: .buildSystemsExtension(target.pluginID),
            pluginID: target.pluginID
        )
        let endBackendProcesses = endBackendProcesses
        session.stuckSendGrace = stuckSendGrace
        session.terminateProcess = { endBackendProcesses(backendToken, true) }
        session.onReleased = { endBackendProcesses(backendToken, false) }
        entry.session = session
        try await waitUntilReady(session, rootURL: target.workspaceURL)
        // A queued ready event can race a stop while initialize is suspended.
        try Task.checkCancellation()
        guard running[target] === entry else { throw CancellationError() }
        return session
    }

    /// Starts the session and returns once `initialize` succeeded. A process
    /// that fails or exits first ends the wait with its own message.
    private func waitUntilReady(_ session: LanguageServerRuntimeSession, rootURL: URL) async throws {
        var finished = false
        defer { session.onStateChange = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            session.onStateChange = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let failure):
                    finish(.failure(UnavailableError(
                        message: failure.message ?? String(localized: "The build provider failed to start.")
                    )))
                case .stopped:
                    finish(.failure(UnavailableError(
                        message: String(localized: "The build provider stopped before it was ready.")
                    )))
                case .startingProcess, .initializing, .stopping:
                    break
                }
            }
            do {
                try session.start(rootURL: rootURL, workspaceFingerprint: nil)
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// A packaged file starts as it is. Commands and runtimes resolve through
    /// the build tool discovery, so the provider sees the same runtime and
    /// `PATH` as the build system's commands.
    private func resolveExecutable(
        _ process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess,
        workspaceURL: URL
    ) async throws -> (URL, [String: String]) {
        let runtimes = process.runtimeTools.map {
            BuildInvocation.RuntimeDependency(id: $0, hostManaged: true)
        }
        let invocation: BuildInvocation
        var requirement: LanguageServerExecutableVersionRequirement?
        switch process.executable {
        case .file(let url):
            return (url, runtime.languageToolProcessEnvironment(runtimeTools: process.runtimeTools))
        case .commands(let commands):
            invocation = BuildInvocation(executables: commands.map { .command($0) }, runtimeDependencies: runtimes)
        case .runtime(let tool, let versionRequirement):
            requirement = versionRequirement
            invocation = BuildInvocation(
                executables: [.runtime(tool)],
                runtimeDependencies: [BuildInvocation.RuntimeDependency(
                    id: tool,
                    hostManaged: true,
                    minimumVersion: versionRequirement?.minimumVersion,
                    versionArguments: versionRequirement?.probeArguments
                )] + runtimes
            )
        }
        let versionChecker = versionChecker
        let resolved = try await tools.resolve(
            invocation,
            displayName: String(localized: "Build provider"),
            workspaceURL: workspaceURL,
            checkVersion: { [requirement] _, output in
                guard let requirement else { return BuildVersionCheck(satisfied: true, version: nil) }
                let check = try versionChecker.checkRuntimeVersion(requirement, output: output)
                return BuildVersionCheck(satisfied: check.satisfied, version: check.version)
            }
        )
        return (resolved.executableURL, resolved.environment)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
