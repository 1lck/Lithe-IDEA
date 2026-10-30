import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI

// Note: 插件后端与宿主凭据服务的决策见 .agents/notes/implemented/architecture/2026-10-24-database-provider-plugin.md
// Note: backend 2 的激活事件、工作区上下文与宿主服务分发见 .agents/notes/implemented/architecture/2026-10-30-plugin-backend-workspace-context.md

/// The backends of plugins (`backend` 1): one process per plugin for the
/// whole application, shared by every project window, because what a
/// backend holds, such as database connections, belongs to the user rather
/// than to a project.
///
/// A process starts on the first `functions.*` call from one of the
/// plugin's pages, or, for `backend` 2, on its `onWorkspaceOpen` or
/// `onCommand:<id>` activation event, and runs until the plugin is disabled, its package is
/// replaced or removed, or the application quits. Its root and working
/// directory is its `${stateDir}`, outside the app bundle and the package.
/// It may request only the host services its permissions grant; Core checks
/// each request, and `hostDispatcher` performs it for that plugin alone.
@MainActor
final class MacPluginBackendSessions: PluginBackendRequesting, PluginBackendActivating {
    /// Shared by every project window's container; the first container
    /// creates it.
    private static var sharedInstance: MacPluginBackendSessions?

    static func shared(make: () -> MacPluginBackendSessions) -> MacPluginBackendSessions {
        if let sharedInstance { return sharedInstance }
        let created = make()
        sharedInstance = created
        return created
    }

    struct UnavailableError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The installed package a backend starts from.
    struct Package: Equatable {
        let manifest: Data
        let packageURL: URL
        /// How the package was installed, for `prepareState`.
        let installation: PluginInstallationRecord
        /// The manifest's activation events, as Core accepted them. Only
        /// a `backend` 2 starts on them; a `backend` 1 waits for its page.
        var activationEvents: [String] = []
        /// `requires.backend` of the manifest.
        var backendVersion = 1
    }

    /// `requires.backend` of a normalized manifest; 1 when it cannot be read.
    static func backendVersion(ofManifest manifest: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let requires = object["requires"] as? [String: Any],
              let version = requires["backend"] as? Int else { return 1 }
        return version
    }

    private let launchResolver: MacPluginLanguageServerLaunchResolver
    private let tools: any BuildToolResolving
    private let versionChecker: any LanguageServerRuntimeVersionChecking
    private let runtime: any LanguageToolRuntimePort
    private let core: any LanguageServerRuntimeCore
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let credentials: any PluginCredentialStoring
    private let prepareState: @Sendable (_ installation: PluginInstallationRecord, _ stateDirectory: URL) -> Void
    private let endBackendProcesses: @MainActor (_ token: String, _ immediately: Bool) -> Void
    private let stuckSendGrace: Duration
    /// Serves the host requests of every backend.
    let hostDispatcher: PluginHostServiceDispatcher
    /// Reports a backend that an activation event failed to start; the
    /// workspace or command goes on without it.
    var onActivationFailure: (@MainActor (_ pluginID: String, _ error: Error) -> Void)?
    /// Starts activated backends one plugin at a time.
    private var activationQueue: Task<Void, Never>?
    private var packages: [String: Package] = [:]
    /// Disabled plugins start again once enabled.
    private var disabledPluginIDs: Set<String> = []
    /// A replaced or removed package never starts again in this launch.
    private var replacedPluginIDs: Set<String> = []
    private var running: [String: Running] = [:]
    private var contextObserver: UUID?

    /// One process, from its start until it is dropped. `session` is set as
    /// soon as the process is launched, so a stop during initialize ends it.
    private final class Running {
        let settings: [String: ToolingJSONValue]
        var task: Task<LanguageServerRuntimeSession, Error>?
        var session: LanguageServerRuntimeSession?
        /// What Core granted the session, set when the process launches.
        var hostServices: Set<String> = []
        /// Notifications reach the backend in the order the host sent them.
        var notifications: Task<Void, Never>?

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
        credentials: any PluginCredentialStoring,
        prepareState: @escaping @Sendable (_ installation: PluginInstallationRecord, _ stateDirectory: URL) -> Void = { _, _ in },
        stuckSendGrace: Duration = .seconds(2),
        hostDispatcher: PluginHostServiceDispatcher? = nil,
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
        self.credentials = credentials
        self.prepareState = prepareState
        self.stuckSendGrace = stuckSendGrace
        self.endBackendProcesses = endBackendProcesses
        if let hostDispatcher {
            self.hostDispatcher = hostDispatcher
        } else {
            let dispatcher = PluginHostServiceDispatcher(contexts: .shared)
            dispatcher.register(PluginCredentialHostService(credentials: credentials))
            self.hostDispatcher = dispatcher
        }
        // Running backends learn of every opened, changed, or closed
        // context; one that starts later asks `listContexts` itself.
        contextObserver = self.hostDispatcher.contexts.observeRevision { [weak self] revision in
            self?.contextsDidChange(revision: revision)
        }
        self.hostDispatcher.subscriptions.deliver = { [weak self] pluginID, params in
            self?.notify(pluginID: pluginID, method: "lithe/host/subscriptions/notify", params: params)
        }
    }

    /// Records the backends of the plugins loaded at launch. Every project
    /// window registers the same startup snapshot; a package installed later
    /// waits for the next launch like its pages. A plugin registered while
    /// a workspace is already open gets its `onWorkspaceOpen` at once.
    func register(_ plugins: [InstalledPluginPackage]) {
        var added: Set<String> = []
        for plugin in plugins where plugin.descriptor.declaresBackend {
            let id = plugin.descriptor.id.rawValue
            guard !replacedPluginIDs.contains(id), packages[id] == nil else { continue }
            packages[id] = Package(
                manifest: plugin.descriptor.normalizedManifest,
                packageURL: plugin.packageURL,
                installation: plugin.installation,
                activationEvents: plugin.descriptor.activationEvents,
                backendVersion: Self.backendVersion(ofManifest: plugin.descriptor.normalizedManifest)
            )
            added.insert(id)
        }
        activateForOpenWorkspaces(added)
    }

    func declaresBackend(_ pluginID: String) -> Bool {
        packages[pluginID] != nil
    }

    func pluginFunctions(ofPlugin pluginID: String) async throws -> [String] {
        try await session(for: pluginID).functionIDs
    }

    func invokePluginFunction(
        _ functionID: String,
        params: ToolingJSONValue,
        ofPlugin pluginID: String,
        timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        try await invokePluginFunction(
            functionID, params: params, ofPlugin: pluginID, context: nil, timeout: timeout, progress: progress
        )
    }

    func invokePluginFunction(
        _ functionID: String,
        params: ToolingJSONValue,
        ofPlugin pluginID: String,
        context: PluginWorkspaceContextReference?,
        timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        let session = try await session(for: pluginID)
        let components = timeout.components
        let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
        return try await session.invokeFunction(
            functionID, params: params, context: context, timeout: seconds, progress: progress
        )
    }

    /// Plugins whose backend starts on `event`, such as `onWorkspaceOpen`
    /// or `onCommand:<id>`. `owner` limits a command to the plugin whose UI
    /// module declares it.
    func pluginIDs(activatedBy event: String, owner: ModuleID? = nil) -> [String] {
        packages.filter { id, package in
            package.backendVersion >= 2
                && package.activationEvents.contains(event)
                && !disabledPluginIDs.contains(id)
                && (owner == nil || owner == ModuleID("\(id).ui"))
        }.keys.sorted()
    }

    /// Starts the backends the event activates, after what is queued, one
    /// plugin at a time and without the caller waiting: a slow or failing
    /// backend never holds up the workspace or the command. A backend that
    /// is already running stays as it is.
    func activate(event: String, owner: ModuleID? = nil) {
        start(pluginIDs(activatedBy: event, owner: owner).filter { running[$0] == nil })
    }

    /// Queues the start of each plugin's backend; `then` runs for each one
    /// that is ready, in the queue's order.
    private func start(
        _ pluginIDs: [String],
        then: (@MainActor (_ pluginID: String) -> Void)? = nil
    ) {
        guard !pluginIDs.isEmpty else { return }
        let previous = activationQueue
        activationQueue = Task { @MainActor [weak self] in
            await previous?.value
            for pluginID in pluginIDs {
                guard let self, !Task.isCancelled else { return }
                do {
                    _ = try await self.session(for: pluginID)
                    then?(pluginID)
                } catch {
                    if !(error is CancellationError) { self.onActivationFailure?(pluginID, error) }
                }
            }
        }
    }

    /// The plugins among `pluginIDs` that start on `onWorkspaceOpen` start
    /// now when a workspace is already open, as if it had just opened.
    private func activateForOpenWorkspaces(_ pluginIDs: Set<String>) {
        guard !pluginIDs.isEmpty, !hostDispatcher.contexts.contexts.isEmpty else { return }
        start(self.pluginIDs(activatedBy: "onWorkspaceOpen").filter {
            pluginIDs.contains($0) && running[$0] == nil
        })
    }

    func runCommand(_ commandID: String, owner: ModuleID, context: PluginWorkspaceContextReference?) {
        let pluginID = String(owner.rawValue.dropLast(".ui".count))
        guard owner.rawValue.hasSuffix(".ui"), let package = packages[pluginID], package.backendVersion >= 2,
              !disabledPluginIDs.contains(pluginID) else { return }
        var params: [String: ToolingJSONValue] = ["commandID": .string(commandID)]
        if let context {
            params["context"] = .object([
                "contextID": .string(context.contextID), "generation": .integer(context.generation),
            ])
        }
        let deliver: @MainActor (String) -> Void = { [weak self] pluginID in
            self?.notify(pluginID: pluginID, method: "lithe/host/commands/didRun", params: .object(params))
        }
        // A ready backend gets it in order with the notifications sent from
        // now; a starting one after its start. A stopped one starts only on
        // its own `onCommand:<id>`.
        if running[pluginID]?.session != nil {
            deliver(pluginID)
        } else if running[pluginID] != nil || package.activationEvents.contains("onCommand:\(commandID)") {
            start([pluginID], then: deliver)
        }
    }

    /// Tells every running backend granted `workspace` that the contexts
    /// changed; it asks `listContexts` for them.
    private func contextsDidChange(revision: Int) {
        for (pluginID, entry) in running where entry.hostServices.contains("workspace") {
            notify(pluginID: pluginID, method: "lithe/host/workspace/didChangeContexts",
                   params: .object(["revision": .integer(revision)]))
        }
    }

    /// Sends a host notification to the plugin's running backend, after the
    /// ones sent before it. A backend that is not running, or negotiated a
    /// protocol without the notification, does not receive it.
    private func notify(pluginID: String, method: String, params: ToolingJSONValue) {
        guard let entry = running[pluginID], let session = entry.session else { return }
        let previous = entry.notifications
        entry.notifications = Task { @MainActor in
            await previous?.value
            _ = await session.notify(method: method, params: params)
        }
    }

    /// Stops the backend until `enable` is called.
    func disable(_ pluginID: String) {
        disabledPluginIDs.insert(pluginID)
        stop(pluginID)
    }

    /// The backend may start again; with a workspace open, one that starts
    /// on `onWorkspaceOpen` starts now instead of with the next workspace.
    func enable(_ pluginID: String) {
        disabledPluginIDs.remove(pluginID)
        activateForOpenWorkspaces([pluginID])
    }

    /// Stops the backend before its package is replaced, rolled back, or
    /// uninstalled; it does not start again from the old files.
    func packageWillChange(_ pluginID: String) {
        replacedPluginIDs.insert(pluginID)
        packages[pluginID] = nil
        stop(pluginID)
    }

    private func stop(_ pluginID: String) {
        hostDispatcher.endSession(pluginID: pluginID)
        guard let entry = running.removeValue(forKey: pluginID) else { return }
        entry.task?.cancel()
        entry.notifications?.cancel()
        entry.session?.stop()
    }

    // MARK: Start

    /// The plugin's running backend, started on first use. A process that
    /// exited is replaced, and so is one started with other setting values.
    private func session(for pluginID: String) async throws -> LanguageServerRuntimeSession {
        try Task.checkCancellation()
        guard let package = packages[pluginID], !disabledPluginIDs.contains(pluginID) else {
            throw PluginFunctionFailure(
                code: "plugin.function.unavailable",
                message: L10n.string("This plugin has no backend that can run now.")
            )
        }
        let settings = launchResolver.backendSettingValues(forPlugin: pluginID)
        if let entry = running[pluginID], let task = entry.task {
            if entry.settings == settings, entry.session?.isRunning != false {
                let session = try await Self.waitForStart(task)
                guard running[pluginID] === entry else { throw CancellationError() }
                return session
            }
            stop(pluginID)
        }
        let backend = try launchResolver.resolveBackend(
            pluginID: pluginID, manifest: package.manifest, packageURL: package.packageURL
        )
        // Another call may have started the process meanwhile.
        if let entry = running[pluginID], let task = entry.task {
            return try await Self.waitForStart(task)
        }
        let entry = Running(settings: backend.process.settings)
        running[pluginID] = entry
        // The start is shared by every call that arrives meanwhile, so no
        // single caller's cancellation cancels it; a failed start clears
        // the entry itself.
        let task = Task { @MainActor [weak self] () throws -> LanguageServerRuntimeSession in
            guard let self else { throw CancellationError() }
            do {
                return try await self.launch(backend, pluginID: pluginID, installation: package.installation, entry: entry)
            } catch {
                if self.running[pluginID] === entry { self.running[pluginID] = nil }
                throw error
            }
        }
        entry.task = task
        let session = try await Self.waitForStart(task)
        guard running[pluginID] === entry else { throw CancellationError() }
        return session
    }

    private func launch(
        _ backend: MacPluginLanguageServerLaunchResolver.BackendProcess,
        pluginID: String,
        installation: PluginInstallationRecord,
        entry: Running
    ) async throws -> LanguageServerRuntimeSession {
        // Data the host moves into a plugin lands before its backend reads
        // its state. The work touches files and the Keychain, so it runs
        // off the main actor.
        let prepareState = prepareState
        let stateDirectory = backend.stateDirectory
        await Task.detached(priority: .userInitiated) { prepareState(installation, stateDirectory) }.value
        try Task.checkCancellation()
        guard running[pluginID] === entry else { throw CancellationError() }
        var (executableURL, environment) = try await resolveExecutable(backend.process, directory: backend.stateDirectory)
        try Task.checkCancellation()
        guard running[pluginID] === entry else { throw CancellationError() }
        // Every process the backend starts inherits this token, so what it
        // leaves behind can be ended when the backend is gone.
        let backendToken = UUID().uuidString
        environment.merge(MacPluginBackendProcesses.environment(token: backendToken)) { _, token in token }
        // Core lists in `getCapabilities` what it grants, so it is granted
        // only what this host serves: a listed method never fails for want
        // of a handler.
        let served = Set(hostDispatcher.registeredServices)
        let hostServices = backend.hostServices.filter { served.contains($0) }
        let session = LanguageServerRuntimeSession(
            providerID: "pluginBackend:\(pluginID)",
            executableURL: executableURL,
            arguments: backend.process.arguments,
            environment: environment,
            initializationOptions: backend.process.initializationOptions,
            initializeTimeout: 60,
            core: core,
            processRegistry: processRegistry,
            // Memory is attributed to the plugin's UI module, whose pages
            // are the backend's only callers.
            moduleID: ModuleID("\(pluginID).ui"),
            pluginID: pluginID,
            hostServices: hostServices
        )
        let endBackendProcesses = endBackendProcesses
        let hostDispatcher = hostDispatcher
        session.stuckSendGrace = stuckSendGrace
        session.terminateProcess = { endBackendProcesses(backendToken, true) }
        session.onReleased = { endBackendProcesses(backendToken, false) }
        // A new process starts with no subscriptions and nothing in flight.
        hostDispatcher.endSession(pluginID: pluginID)
        hostDispatcher.beginSession(pluginID: pluginID, hostServices: hostServices)
        entry.hostServices = Set(hostServices)
        session.onHostRequest = { [weak session] request in
            hostDispatcher.handle(request, pluginID: pluginID) { outcome in
                session?.respond(to: request.id, with: outcome)
            }
        }
        session.onHostRequestCancelled = { hostRequestID in
            hostDispatcher.cancel(hostRequestID: hostRequestID, pluginID: pluginID)
        }
        entry.session = session
        try await waitUntilReady(session, rootURL: backend.stateDirectory)
        try Task.checkCancellation()
        guard running[pluginID] === entry else { throw CancellationError() }
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
                        message: failure.message ?? L10n.string("The plugin backend failed to start.")
                    )))
                case .stopped:
                    finish(.failure(UnavailableError(
                        message: L10n.string("The plugin backend stopped before it was ready.")
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
    /// the build tool discovery, with the backend's state directory as the
    /// place a project-local tool would be looked up.
    private func resolveExecutable(
        _ process: MacPluginLanguageServerLaunchResolver.BuildProviderProcess,
        directory: URL
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
            displayName: L10n.string("Plugin backend"),
            workspaceURL: directory,
            checkVersion: { [requirement] _, output in
                guard let requirement else { return BuildVersionCheck(satisfied: true, version: nil) }
                let check = try versionChecker.checkRuntimeVersion(requirement, output: output)
                return BuildVersionCheck(satisfied: check.satisfied, version: check.version)
            }
        )
        return (resolved.executableURL, resolved.environment)
    }

    /// Waits for a shared start. A cancelled caller stops waiting at once,
    /// while the start goes on for the other callers.
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
}
