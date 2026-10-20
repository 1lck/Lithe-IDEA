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
/// and runs until `retainProviders` drops its target: a workspace switch, a
/// disabled or updated plugin, or the app quitting. Its writable state lives
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
    private var running: [BuildProviderTarget: Running] = [:]

    /// One process, from its start until it is dropped. `session` is set as
    /// soon as the process is launched, so a drop during initialize stops it.
    private final class Running {
        let id = UUID()
        var task: Task<LanguageServerRuntimeSession, Error>?
        var session: LanguageServerRuntimeSession?
    }

    init(
        launchResolver: MacPluginLanguageServerLaunchResolver,
        tools: any BuildToolResolving,
        versionChecker: any LanguageServerRuntimeVersionChecking,
        runtime: any LanguageToolRuntimePort,
        core: any LanguageServerRuntimeCore,
        processRegistry: (any LanguageServerProcessRegistry)?
    ) {
        self.launchResolver = launchResolver
        self.tools = tools
        self.versionChecker = versionChecker
        self.runtime = runtime
        self.core = core
        self.processRegistry = processRegistry
    }

    func send(
        _ request: BuildProviderRequest,
        to target: BuildProviderTarget,
        timeout: Duration
    ) async throws -> ToolingJSONValue {
        let seconds = Self.seconds(timeout)
        if let session = try await runningSession(for: target) {
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
            return try await session.buildRequest(method: request.method, params: request.params, timeout: seconds)
        }
    }

    func retainProviders(_ keep: (BuildProviderTarget) -> Bool) {
        for (target, entry) in running where !keep(target) {
            running[target] = nil
            entry.task?.cancel()
            entry.session?.stop()
        }
    }

    /// The process already started for `target`; nil when none runs. A
    /// process that exited or crashed is replaced by the next request.
    private func runningSession(for target: BuildProviderTarget) async throws -> LanguageServerRuntimeSession? {
        guard let entry = running[target], let task = entry.task else { return nil }
        if let session = entry.session, !session.isRunning {
            running[target] = nil
            return nil
        }
        return try await task.value
    }

    private func startSession(
        for target: BuildProviderTarget,
        process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess
    ) async throws -> LanguageServerRuntimeSession {
        // Another request may have started the process while this one
        // resolved the launch.
        if let session = try await runningSession(for: target) { return session }
        let entry = Running()
        running[target] = entry
        let task = Task { @MainActor [weak self] () throws -> LanguageServerRuntimeSession in
            guard let self else { throw CancellationError() }
            return try await self.launch(process, for: target, entry: entry)
        }
        entry.task = task
        do {
            return try await task.value
        } catch {
            if running[target] === entry { running[target] = nil }
            throw error
        }
    }

    private func launch(
        _ process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess,
        for target: BuildProviderTarget,
        entry: Running
    ) async throws -> LanguageServerRuntimeSession {
        let (executableURL, environment) = try await resolveExecutable(process, workspaceURL: target.workspaceURL)
        try Task.checkCancellation()
        guard running[target] === entry else { throw CancellationError() }
        let session = LanguageServerRuntimeSession(
            providerID: "buildProvider:\(target.pluginID):\(target.buildSystemID)",
            executableURL: executableURL,
            arguments: process.arguments,
            environment: environment,
            initializationOptions: process.initializationOptions,
            initializeTimeout: 60,
            core: core,
            processRegistry: processRegistry,
            moduleID: .buildSystemsExtension(target.pluginID)
        )
        entry.session = session
        try await waitUntilReady(session, rootURL: target.workspaceURL)
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
