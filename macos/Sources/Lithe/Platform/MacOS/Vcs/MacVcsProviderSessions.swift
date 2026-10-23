import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// Provider processes of plugin VCS providers. Each process belongs to one
/// VCS of one plugin in one workspace and talks only to the host over its
/// own stdio channel, so no plugin can reach another plugin's provider.
///
/// A process starts on the first request for a detected root of its VCS and
/// runs until `retainProviders` drops its target (a workspace switch, a
/// disabled plugin) or `stopProviders(ofPlugin:)` stops it before its
/// package is replaced or removed. A change of the plugin's settings
/// restarts it on the next request. Its writable state lives in the
/// provider's plugin state directory, never in the app bundle or the plugin
/// package.
@MainActor
final class MacVcsProviderSessions: VcsProviderRequesting {
    struct UnavailableError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    private let launchResolver: MacPluginLanguageServerLaunchResolver
    private let tools: any BuildToolResolving
    private let versionChecker: any LanguageServerRuntimeVersionChecking
    private let runtime: any LanguageToolRuntimePort
    private let core: any LanguageServerRuntimeCore
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    /// Ends the processes carrying a backend's token; `immediately` skips the
    /// graceful stop. See `MacPluginBackendProcesses`.
    private let endBackendProcesses: @MainActor (_ token: String, _ immediately: Bool) -> Void
    private var running: [VcsProviderTarget: Running] = [:]

    /// One process, from its start until it is dropped.
    private final class Running {
        let settings: [String: ToolingJSONValue]
        var task: Task<Started, Error>?
        var session: LanguageServerRuntimeSession?

        init(settings: [String: ToolingJSONValue]) {
            self.settings = settings
        }
    }

    /// A ready session with what it negotiated and the client every request
    /// names.
    private struct Started {
        let session: LanguageServerRuntimeSession
        let negotiation: VcsProviderNegotiation
        let toolPath: String?
    }

    init(
        launchResolver: MacPluginLanguageServerLaunchResolver,
        tools: any BuildToolResolving,
        versionChecker: any LanguageServerRuntimeVersionChecking,
        runtime: any LanguageToolRuntimePort,
        core: any LanguageServerRuntimeCore,
        processRegistry: (any LanguageServerProcessRegistry)?,
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
    }

    func negotiation(for target: VcsProviderTarget) async throws -> VcsProviderNegotiation {
        try await started(for: target).negotiation
    }

    func send(
        _ operation: VcsOperation,
        root: String,
        to target: VcsProviderTarget,
        timeout: Duration
    ) async throws -> VcsProviderReply {
        let started = try await started(for: target)
        guard started.negotiation.supports(operation.capability) else {
            throw VcsProviderFailure(
                code: "vcs.capability.unsupported",
                message: String(localized: "This version control provider does not support this action.")
            )
        }
        do {
            let value = try await started.session.vcsRequest(
                vcs: target.vcs,
                operation: operation.name,
                root: root,
                tool: started.toolPath,
                arguments: operation.arguments,
                timeout: Self.seconds(timeout)
            )
            return VcsProviderReply(value: value, negotiation: started.negotiation)
        } catch let failure as LanguageServerRequestFailure {
            throw VcsProviderFailure(code: failure.runtimeError.code, message: failure.runtimeError.message)
        }
    }

    func retainProviders(_ keep: (VcsProviderTarget) -> Bool) {
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

    private func stop(_ entry: Running, for target: VcsProviderTarget) {
        if running[target] === entry { running[target] = nil }
        entry.task?.cancel()
        entry.session?.stop()
    }

    /// The target's running process, or a new one. A process that exited is
    /// replaced, and so is one started with other setting values.
    private func started(for target: VcsProviderTarget) async throws -> Started {
        try Task.checkCancellation()
        let settings = launchResolver.settingValues(forPlugin: target.pluginID, workspaceRootURL: target.workspaceURL)
        if let entry = running[target], let task = entry.task {
            if entry.settings != settings || entry.session.map({ !$0.isRunning }) == true {
                stop(entry, for: target)
            } else {
                let started = try await Self.waitForStart(task)
                guard running[target] === entry else { throw CancellationError() }
                return started
            }
        }
        let entry = Running(settings: settings)
        running[target] = entry
        // The start is shared by every request that arrives meanwhile, so no
        // single caller's cancellation cancels it; a failed start clears the
        // entry itself.
        let task = Task { @MainActor [weak self] () throws -> Started in
            guard let self else { throw CancellationError() }
            do {
                return try await self.launch(target, entry: entry)
            } catch {
                if self.running[target] === entry { self.running[target] = nil }
                throw error
            }
        }
        entry.task = task
        let started = try await Self.waitForStart(task)
        guard running[target] === entry else { throw CancellationError() }
        return started
    }

    /// Waits for a shared start. A cancelled caller stops waiting at once,
    /// while the start goes on for the other callers.
    private static func waitForStart(_ task: Task<Started, Error>) async throws -> Started {
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
        private var continuation: CheckedContinuation<Started, Error>?

        func wait(with continuation: CheckedContinuation<Started, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Started, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func launch(_ target: VcsProviderTarget, entry: Running) async throws -> Started {
        let provider = try launchResolver.resolveVcsProvider(
            pluginID: target.pluginID,
            vcs: target.vcs,
            manifest: target.manifest,
            packageURL: target.packageURL,
            workspaceRootURL: target.workspaceURL
        )
        var (executableURL, environment) = try await resolveExecutable(provider.process, workspaceURL: target.workspaceURL)
        let toolPath = try await resolveTool(provider, workspaceURL: target.workspaceURL)
        try Task.checkCancellation()
        guard running[target] === entry else { throw CancellationError() }
        // Every process the backend starts, the VCS client included, inherits
        // this token, so what it leaves behind can be ended when it is gone.
        let backendToken = UUID().uuidString
        environment.merge(MacPluginBackendProcesses.environment(token: backendToken)) { _, token in token }
        let session = LanguageServerRuntimeSession(
            providerID: "vcsProvider:\(target.pluginID):\(target.vcs)",
            executableURL: executableURL,
            arguments: provider.process.arguments,
            environment: environment,
            initializationOptions: provider.process.initializationOptions,
            initializeTimeout: 60,
            core: core,
            processRegistry: processRegistry,
            moduleID: .vcsProvidersExtension(target.pluginID),
            pluginID: target.pluginID
        )
        let endBackendProcesses = endBackendProcesses
        session.terminateProcess = { endBackendProcesses(backendToken, true) }
        session.onReleased = { endBackendProcesses(backendToken, false) }
        entry.session = session
        try await waitUntilReady(session, rootURL: target.workspaceURL)
        try Task.checkCancellation()
        guard running[target] === entry else { throw CancellationError() }
        // Core publishes the negotiation before the session is ready. A
        // process that answered no provider, or another VCS than the
        // manifest entry it was launched for, is stopped.
        guard let negotiation = session.vcsNegotiation, negotiation.vcs == target.vcs else {
            session.stop()
            throw UnavailableError(message: String(
                localized: "The plugin's version control provider did not start as declared. Update or reinstall the plugin."
            ))
        }
        return Started(session: session, negotiation: negotiation, toolPath: toolPath)
    }

    /// Starts the session and returns once `initialize` succeeded.
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
                        message: failure.message ?? String(localized: "The version control provider failed to start.")
                    )))
                case .stopped:
                    finish(.failure(UnavailableError(
                        message: String(localized: "The version control provider stopped before it was ready.")
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

    /// The provider's own executable: a packaged file as it is, commands and
    /// runtimes through the build tool discovery, so the provider sees the
    /// same runtime settings and `PATH` as other plugin processes.
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
            displayName: String(localized: "Version control provider"),
            workspaceURL: workspaceURL,
            checkVersion: { [requirement] _, output in
                guard let requirement else { return BuildVersionCheck(satisfied: true, version: nil) }
                let check = try versionChecker.checkRuntimeVersion(requirement, output: output)
                return BuildVersionCheck(satisfied: check.satisfied, version: check.version)
            }
        )
        return (resolved.executableURL, resolved.environment)
    }

    /// The VCS client the provider runs, such as `svn`, found like any other
    /// command. The provider itself reports a client that is too old; one
    /// that cannot be found is `vcs.tool.unavailable`, as the contract names it.
    private func resolveTool(
        _ provider: MacPluginLanguageServerLaunchResolver.VcsProviderProcess,
        workspaceURL: URL
    ) async throws -> String? {
        guard !provider.toolCommands.isEmpty else { return nil }
        do {
            let resolved = try await tools.resolve(
                BuildInvocation(executables: provider.toolCommands.map { .command($0) }),
                displayName: provider.toolCommands[0],
                workspaceURL: workspaceURL,
                checkVersion: { _, _ in BuildVersionCheck(satisfied: true, version: nil) }
            )
            return resolved.executableURL.path
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VcsProviderFailure(code: "vcs.tool.unavailable", message: error.localizedDescription)
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
