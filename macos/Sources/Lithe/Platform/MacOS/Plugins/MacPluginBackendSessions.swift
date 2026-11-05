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

    struct KeymapImportResult: Sendable {
        let response: ToolingJSONValue
        let sourceDigest: String
        let sourceFileCount: Int
    }

    struct KeymapProvider: Equatable, Sendable {
        let pluginID: String
        let id: String
        let displayName: String
    }

    private struct KeymapCandidate: Sendable {
        let provider: KeymapProvider
        let manifest: Data
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
    private let canStart: @MainActor (String) -> Bool
    private let stuckSendGrace: Duration
    /// Serves the host requests of every backend.
    let hostDispatcher: PluginHostServiceDispatcher
    private let keymapImportHost = MacKeymapImportHostService()
    /// Reports a backend that an activation event failed to start; the
    /// workspace or command goes on without it.
    var editorActions: PluginEditorActionHostService?
    var editorProviders: PluginEditorProviderHostService?
    var onActivationFailure: (@MainActor (_ pluginID: String, _ error: Error) -> Void)?
    private static let maximumBackgroundStarts = 2
    private static let maximumPendingNotifications = 128
    private var backgroundQueue: [String] = []
    private var backgroundStarts: [String: Task<Void, Never>] = [:]
    private var commandStarts: [String: Task<Void, Never>] = [:]
    /// Starts a call between plugins waits for, one per plugin.
    private var providerStarts: [String: Task<Void, Never>] = [:]
    /// The last snapshot Core's relay accepted; an unchanged one is not sent again.
    private var publishedRelaySnapshot: PluginFunctionRelaySnapshot?
    private var pendingCommands: [String: [ToolingJSONValue]] = [:]
    private var packages: [String: Package] = [:]
    /// Disabled plugins start again once enabled.
    private var disabledPluginIDs: Set<String> = []
    /// A replaced or removed package never starts again in this launch.
    private var replacedPluginIDs: Set<String> = []
    private var running: [String: Running] = [:]
    private var activeKeymapImports: [String: Int] = [:]
    private var contextObserver: UUID?

    /// One process, from its start until it is dropped. `session` is set as
    /// soon as the process is launched, so a stop during initialize ends it.
    private final class Running {
        let settings: [String: ToolingJSONValue]
        var task: Task<LanguageServerRuntimeSession, Error>?
        var session: LanguageServerRuntimeSession?
        var hostSessionID: String?
        var ready = false
        /// What Core granted the session, set when the process launches.
        var hostServices: Set<String> = []
        /// Notifications reach the backend in the order the host sent them.
        var notifications: Task<Void, Never>?
        var notificationQueue: [(method: String, params: ToolingJSONValue)] = []

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
        canStart: @escaping @MainActor (String) -> Bool = { _ in true },
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
        self.canStart = canStart
        self.endBackendProcesses = endBackendProcesses
        if let hostDispatcher {
            self.hostDispatcher = hostDispatcher
        } else {
            let dispatcher = PluginHostServiceDispatcher(contexts: .shared)
            dispatcher.register(PluginCredentialHostService(credentials: credentials))
            self.hostDispatcher = dispatcher
        }
        self.hostDispatcher.register(keymapImportHost)
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
        publishFunctionRelay()
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

    /// Provider IDs a normalized manifest declares, offered during `initialize`.
    static func toolchainProviderIDs(ofManifest manifest: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let providers = object["toolchainProviders"] as? [[String: Any]] else { return [] }
        return providers.compactMap { $0["id"] as? String }
    }

    /// Provider IDs already accepted by Core's normalized manifest validation.
    static func keymapImportProviderIDs(ofManifest manifest: Data) -> [String] {
        keymapProviderDeclarations(ofManifest: manifest).map(\.id)
    }

    private struct KeymapProviderDeclaration: Decodable {
        let id: String
        let displayName: String
    }

    private struct KeymapProviderManifest: Decodable {
        let keymapImportProviders: [KeymapProviderDeclaration]?
    }

    private static func keymapProviderDeclarations(ofManifest manifest: Data) -> [KeymapProviderDeclaration] {
        (try? JSONDecoder().decode(KeymapProviderManifest.self, from: manifest).keymapImportProviders) ?? []
    }

    /// A provider-only backend belongs to the import workflow, so it can be
    /// stopped as soon as its last import finishes. A multipurpose backend
    /// remains shared with its other consumers.
    static func isKeymapOnlyBackend(manifest: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              !(keymapProviderDeclarations(ofManifest: manifest).isEmpty),
              let permissions = object["permissions"] as? [String],
              Set(permissions).isSubset(of: ["backend.launch", "keymaps.provide", "keymaps.readSelectedSources"]),
              object["ui"] == nil || object["ui"] is NSNull else { return false }
        for key in ["activationEvents", "languageServers", "buildSystems", "debugAdapters", "projectGenerators",
                    "toolchainProviders", "toolDefinitions", "settings", "settingActions", "vcsProviders",
                    "executionProviders", "languages", "outputLinkMatchers"] {
            if let values = object[key] as? [Any], !values.isEmpty { return false }
        }
        return true
    }

    /// Finds matching providers using their accepted, metadata-only probes.
    /// This never launches a backend or reads source file contents.
    func matchingKeymapProviders(root: URL) async throws -> [KeymapProvider] {
        guard let rustCore = core as? RustCoreBridge else { return [] }
        let candidates: [KeymapCandidate] = packages.flatMap { element -> [KeymapCandidate] in
            let (pluginID, package) = element
            guard !disabledPluginIDs.contains(pluginID), !replacedPluginIDs.contains(pluginID), canStart(pluginID) else { return [] }
            return Self.keymapProviderDeclarations(ofManifest: package.manifest).map {
                KeymapCandidate(provider: KeymapProvider(pluginID: pluginID, id: $0.id, displayName: $0.displayName), manifest: package.manifest)
            }
        }.sorted { ($0.provider.pluginID, $0.provider.id) < ($1.provider.pluginID, $1.provider.id) }
        let task = Task.detached(priority: .userInitiated) {
            let operations = RustKeymapImportOperations(core: rustCore)
            var matches: [KeymapCandidate] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let plan = try operations.planSources(manifest: candidate.manifest, providerID: candidate.provider.id)
                if try MacKeymapImportRecognition.matches(root: root, plan: plan) { matches.append(candidate) }
            }
            return matches
        }
        let matches = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return matches.compactMap { candidate in
            let id = candidate.provider.pluginID
            guard packages[id]?.manifest == candidate.manifest, !disabledPluginIDs.contains(id),
                  !replacedPluginIDs.contains(id), canStart(id) else { return nil }
            return candidate.provider
        }
    }

    /// Asks a plugin's provider, starting or reusing its one backend process.
    /// Returns `{ id, response }` unvalidated; see `toolchains.decodeReply`.
    func queryToolchainProvider(
        _ providerID: String, params: ToolingJSONValue, ofPlugin pluginID: String, timeout: TimeInterval
    ) async throws -> ToolingJSONValue {
        let session = try await session(for: pluginID)
        guard session.toolchainProviders.contains(providerID) else {
            throw UnavailableError(message: L10n.string("The plugin backend did not offer this version manager."))
        }
        return try await session.toolchainRequest(params: params, timeout: timeout)
    }

    /// Gives the negotiated importer a temporary, session-owned view of the
    /// Core-planned files under the source the user selected.
    func importKeymap(
        _ providerID: String, selectedRoot: URL, ofPlugin pluginID: String, timeout: TimeInterval
    ) async throws -> KeymapImportResult {
        guard let package = packages[pluginID], let rustCore = core as? RustCoreBridge else {
            throw UnavailableError(message: L10n.string(
                "Shortcut import is unavailable. Update Lithe and the editor import plugin, then try again."
            ))
        }
        let plan = try RustKeymapImportOperations(core: rustCore).planSources(manifest: package.manifest, providerID: providerID)
        let recognition = Task.detached { try MacKeymapImportRecognition.matches(root: selectedRoot, plan: plan) }
        let matches = try await withTaskCancellationHandler { try await recognition.value } onCancel: { recognition.cancel() }
        guard matches else {
            throw UnavailableError(message: L10n.string(
                "Shortcut import is unavailable. Update Lithe and the editor import plugin, then try again."
            ))
        }
        // Count callers before awaiting startup: cancellation or failed
        // negotiation must also release an import-only backend, while another
        // concurrent importer may still be waiting for that same startup.
        activeKeymapImports[pluginID, default: 0] += 1
        defer {
            let remaining = (activeKeymapImports[pluginID] ?? 1) - 1
            if remaining == 0 {
                activeKeymapImports[pluginID] = nil
                if packages[pluginID] == package, Self.isKeymapOnlyBackend(manifest: package.manifest) {
                    stop(pluginID)
                }
            } else {
                activeKeymapImports[pluginID] = remaining
            }
        }
        let session = try await session(for: pluginID)
        guard session.keymapImportProviders.contains(providerID), packages[pluginID] == package,
              let entry = running[pluginID], let hostSessionID = entry.hostSessionID else {
            throw UnavailableError(message: L10n.string(
                "Shortcut import is unavailable. Update Lithe and the editor import plugin, then try again."
            ))
        }
        let task = Task.detached { try MacKeymapImportSnapshot(root: selectedRoot, plan: plan) }
        let snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, running[pluginID] === entry, entry.session === session,
              entry.hostSessionID == hostSessionID else {
            snapshot.close()
            throw CancellationError()
        }
        let token = keymapImportHost.snapshots.insert(snapshot, pluginID: pluginID, sessionID: hostSessionID, providerID: providerID)
        defer { keymapImportHost.snapshots.remove(token) }
        let reply = try await session.keymapImportRequest(providerID: providerID, snapshotID: token, timeout: timeout)
        let validation = Task.detached {
            guard try MacKeymapImportRecognition.matches(root: selectedRoot, plan: plan) else {
                throw MacKeymapImportSnapshot.Failure.sourceChanged
            }
            return try snapshot.contentDigest()
        }
        let digest = try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        _ = try keymapImportHost.snapshots.snapshot(token, pluginID: pluginID, sessionID: hostSessionID, providerID: providerID)
        return KeymapImportResult(response: reply, sourceDigest: digest, sourceFileCount: snapshot.files.count)
    }

    /// Plugins whose backend starts on `event`, such as `onWorkspaceOpen`
    /// or `onCommand:<id>`. `owner` limits a command to the plugin whose UI
    /// module declares it.
    func pluginIDs(activatedBy event: String, owner: ModuleID? = nil) -> [String] {
        packages.filter { id, package in
            package.backendVersion >= 2
                && package.activationEvents.contains(event)
                && !disabledPluginIDs.contains(id) && canStart(id)
                && (owner == nil || owner == ModuleID("\(id).ui"))
        }.keys.sorted()
    }

    /// Queues deduplicated background starts without holding up the workspace.
    /// Explicit commands take the independent per-plugin readiness path.
    func activate(event: String, owner: ModuleID? = nil) {
        start(pluginIDs(activatedBy: event, owner: owner).filter { running[$0] == nil })
    }

    /// Background activation is bounded and deduplicated. User commands have
    /// their own start path so an unrelated slow initialize never delays them.
    private func start(_ pluginIDs: [String]) {
        for id in pluginIDs where backgroundStarts[id] == nil && !backgroundQueue.contains(id) {
            backgroundQueue.append(id)
        }
        drainBackgroundStarts()
    }

    private func drainBackgroundStarts() {
        while backgroundStarts.count < Self.maximumBackgroundStarts, !backgroundQueue.isEmpty {
            let pluginID = backgroundQueue.removeFirst()
            backgroundStarts[pluginID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if !Task.isCancelled { self.backgroundStarts[pluginID] = nil }
                    self.drainBackgroundStarts()
                }
                do {
                    _ = try await self.session(for: pluginID)
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
        if commandStarts[pluginID] == nil, running[pluginID]?.ready == true, running[pluginID]?.session?.isRunning == true {
            notify(pluginID: pluginID, method: "lithe/host/commands/didRun", params: .object(params))
            return
        }
        guard running[pluginID] != nil || package.activationEvents.contains("onCommand:\(commandID)") else { return }
        guard pendingCommands[pluginID, default: []].count < Self.maximumPendingNotifications else {
            reportNotificationLimit(pluginID)
            return
        }
        pendingCommands[pluginID, default: []].append(.object(params))
        guard commandStarts[pluginID] == nil else { return }
        commandStarts[pluginID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.commandStarts[pluginID] = nil } }
            do {
                _ = try await self.session(for: pluginID)
                guard !Task.isCancelled else { return }
                let commands = self.pendingCommands.removeValue(forKey: pluginID) ?? []
                for command in commands {
                    self.notify(pluginID: pluginID, method: "lithe/host/commands/didRun", params: command)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingCommands[pluginID] = nil
                if !(error is CancellationError) { self.onActivationFailure?(pluginID, error) }
            }
        }
    }

    /// Tells every running backend granted `workspace` that the contexts
    /// changed; it asks `listContexts` for them.
    private func contextsDidChange(revision: Int) {
        publishFunctionRelay()
        for (pluginID, entry) in running where entry.hostServices.contains("workspace") {
            notify(pluginID: pluginID, method: "lithe/host/workspace/didChangeContexts",
                   params: .object(["revision": .integer(revision)]))
        }
    }

    /// Sends a host notification to the plugin's running backend, after the
    /// ones sent before it. A backend that is not running, or negotiated a
    /// protocol without the notification, does not receive it.
    private func notify(pluginID: String, method: String, params: ToolingJSONValue) {
        guard let entry = running[pluginID], entry.ready, let session = entry.session else { return }
        if method == "lithe/host/workspace/didChangeContexts" {
            entry.notificationQueue.removeAll { $0.method == method }
        }
        guard entry.notificationQueue.count < Self.maximumPendingNotifications else {
            reportNotificationLimit(pluginID)
            stop(pluginID)
            return
        }
        entry.notificationQueue.append((method, params))
        guard entry.notifications == nil else { return }
        entry.notifications = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            defer { entry.notifications = nil }
            while !Task.isCancelled, self.running[pluginID] === entry, !entry.notificationQueue.isEmpty {
                let next = entry.notificationQueue.removeFirst()
                if next.method == "lithe/host/subscriptions/notify", case .object(let params) = next.params,
                   case .string(let id)? = params["subscriptionID"],
                   !self.hostDispatcher.subscriptions.contains(pluginID: pluginID, subscriptionID: id) { continue }
                if next.method == "lithe/host/commands/didRun", case .object(let params) = next.params,
                   let value = params["context"], let context = PluginHostServiceDispatcher.contextReference(value),
                   case .failure(let error) = self.hostDispatcher.contexts.resolve(context) {
                    self.onActivationFailure?(pluginID, error)
                    continue
                }
                guard await session.notify(method: next.method, params: next.params) != nil else {
                    if !Task.isCancelled, self.running[pluginID] === entry {
                        self.onActivationFailure?(pluginID, PluginHostServiceError(.failed,
                            L10n.string("The plugin host request could not be completed.")))
                        self.stop(pluginID)
                    }
                    return
                }
            }
        }
    }

    private func reportNotificationLimit(_ pluginID: String) {
        onActivationFailure?(pluginID, PluginHostServiceError(
            .limitExceeded, L10n.string("This plugin already has too many messages waiting.")
        ))
    }

    // MARK: Calls between plugins

    /// Reports to Core's relay which plugins are enabled and which workspace
    /// contexts are live. Core decides from these what a call may do; this
    /// side only states the facts, and states them again whenever one of
    /// them changes, so calls in flight see the change.
    private func publishFunctionRelay() {
        let snapshot = functionRelaySnapshot()
        guard snapshot != publishedRelaySnapshot else { return }
        // A snapshot Core did not accept stays unpublished, so the next
        // change sends it again.
        guard case .success = core.configurePluginFunctionRelay(snapshot) else { return }
        publishedRelaySnapshot = snapshot
    }

    private func functionRelaySnapshot() -> PluginFunctionRelaySnapshot {
        let plugins = packages.compactMap { pluginID, package -> PluginFunctionRelaySnapshot.Plugin? in
            guard !disabledPluginIDs.contains(pluginID), !replacedPluginIDs.contains(pluginID), canStart(pluginID),
                  let declaration = Self.pluginFunctionDeclaration(ofManifest: package.manifest) else { return nil }
            return .init(pluginID: pluginID, exports: declaration.exports ?? [], calls: declaration.calls ?? [])
        }
        let contexts = hostDispatcher.contexts.contexts.map { context -> PluginFunctionRelaySnapshot.Context in
            let isRemote: Bool
            if case .remote = context.authority { isRemote = true } else { isRemote = false }
            return .init(contextID: context.contextID, generation: context.generation, isRemote: isRemote)
        }
        return PluginFunctionRelaySnapshot(
            plugins: plugins.sorted { $0.pluginID < $1.pluginID },
            contexts: contexts.sorted { $0.contextID < $1.contextID }
        )
    }

    /// The `pluginFunctions` section of a normalized manifest, left as Core
    /// wrote it: Core validated it once and reads it again in the relay.
    private struct PluginFunctionDeclaration: Decodable {
        let exports: [ToolingJSONValue]?
        let calls: [ToolingJSONValue]?
    }

    private struct PluginFunctionsManifest: Decodable {
        let pluginFunctions: PluginFunctionDeclaration?
    }

    private static func pluginFunctionDeclaration(ofManifest manifest: Data) -> PluginFunctionDeclaration? {
        // log-exempt: Core 已校验过清单；解码失败只会让该插件不进中转快照
        try? JSONDecoder().decode(PluginFunctionsManifest.self, from: manifest).pluginFunctions
    }

    /// Starts the backend a call between plugins waits for. This is the
    /// host's whole part in the call: Core checks and relays it. The start
    /// is bounded like every other one, by the `initialize` time limit, and
    /// a failure is reported here while Core ends the waiting call with its
    /// own error once its wait runs out.
    private func startProviderBackend(_ pluginID: String) {
        guard providerStarts[pluginID] == nil else { return }
        providerStarts[pluginID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.providerStarts[pluginID] = nil } }
            do {
                _ = try await self.session(for: pluginID)
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { self.onActivationFailure?(pluginID, error) }
            }
        }
    }

    /// Stops the backend until `enable` is called.
    func disable(_ pluginID: String) {
        disabledPluginIDs.insert(pluginID)
        stop(pluginID)
        publishFunctionRelay()
    }

    /// The backend may start again; with a workspace open, one that starts
    /// on `onWorkspaceOpen` starts now instead of with the next workspace.
    func enable(_ pluginID: String) {
        disabledPluginIDs.remove(pluginID)
        publishFunctionRelay()
        activateForOpenWorkspaces([pluginID])
    }

    /// Stops the backend before its package is replaced, rolled back, or
    /// uninstalled; it does not start again from the old files.
    func packageWillChange(_ pluginID: String) {
        replacedPluginIDs.insert(pluginID)
        packages[pluginID] = nil
        stop(pluginID)
        publishFunctionRelay()
    }

    private func stop(_ pluginID: String) {
        backgroundQueue.removeAll { $0 == pluginID }
        backgroundStarts.removeValue(forKey: pluginID)?.cancel()
        commandStarts.removeValue(forKey: pluginID)?.cancel()
        providerStarts.removeValue(forKey: pluginID)?.cancel()
        pendingCommands[pluginID] = nil
        hostDispatcher.endSession(pluginID: pluginID)
        guard let entry = running.removeValue(forKey: pluginID) else { return }
        entry.task?.cancel()
        entry.notifications?.cancel()
        entry.notificationQueue = []
        entry.session?.stop()
    }

    // MARK: Start

    /// The plugin's running backend, started on first use. A process that
    /// exited is replaced, and so is one started with other setting values.
    private func session(for pluginID: String) async throws -> LanguageServerRuntimeSession {
        try Task.checkCancellation()
        guard let package = packages[pluginID], !disabledPluginIDs.contains(pluginID), canStart(pluginID) else {
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
                if self.running[pluginID] === entry {
                    self.running[pluginID] = nil
                    self.hostDispatcher.endSession(pluginID: pluginID)
                }
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
        let hostServices = hostDispatcher.supportedGrants(backend.hostServices)
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
            pluginID: pluginID, role: .backend,
            hostServices: hostServices,
            toolchainProviders: packages[pluginID].map { Self.toolchainProviderIDs(ofManifest: $0.manifest) } ?? [],
            keymapImportProviders: packages[pluginID].map { Self.keymapImportProviderIDs(ofManifest: $0.manifest) } ?? []
        )
        let endBackendProcesses = endBackendProcesses
        let hostDispatcher = hostDispatcher
        session.stuckSendGrace = stuckSendGrace
        session.terminateProcess = { endBackendProcesses(backendToken, true) }
        session.onReleased = { [weak self, weak entry] in
            endBackendProcesses(backendToken, false)
            guard let self, let entry, self.running[pluginID] === entry else { return }
            self.running[pluginID] = nil
            entry.ready = false
            entry.notifications?.cancel()
            entry.notificationQueue = []
            hostDispatcher.endSession(pluginID: pluginID)
        }
        // A new process starts with no subscriptions and nothing in flight.
        hostDispatcher.endSession(pluginID: pluginID)
        let sessionToken = hostDispatcher.beginSession(pluginID: pluginID, hostServices: hostServices)
        entry.hostSessionID = sessionToken
        entry.hostServices = Set(hostServices)
        session.onFunctionsChange = { [weak self] ids in
            self?.editorActions?.updateFunctions(pluginID: pluginID, sessionID: sessionToken, ids: ids)
            self?.editorProviders?.updateFunctions(pluginID: pluginID, sessionID: sessionToken, ids: ids)
        }
        session.onHostRequest = { [weak session] request in
            hostDispatcher.handle(request, pluginID: pluginID, sessionID: sessionToken) { outcome in
                session?.respond(to: request.id, with: outcome)
            }
        }
        session.onHostRequestCancelled = { hostRequestID in
            hostDispatcher.cancel(hostRequestID: hostRequestID, pluginID: pluginID, sessionID: sessionToken)
        }
        session.onFunctionProviderStartRequired = { [weak self] providerID in
            self?.startProviderBackend(providerID)
        }
        entry.session = session
        try await waitUntilReady(session, rootURL: backend.stateDirectory)
        try Task.checkCancellation()
        guard running[pluginID] === entry else { throw CancellationError() }
        entry.ready = true
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

/// What the plugin run service needs from the backends: the installed package a run belongs
/// to, and the one-way notice that a run ended.
extension MacPluginBackendSessions: PluginRunBackendLink {
    func manifest(ofPlugin pluginID: String) -> Data? {
        packages[pluginID]?.manifest
    }

    func packageURL(ofPlugin pluginID: String) -> URL? {
        packages[pluginID]?.packageURL
    }

    /// Only the session that saw the run begin hears that it ended: a backend that started
    /// again since knows nothing of the run, and one without the `run.start` grant never asked.
    func notifyRunDidExit(pluginID: String, sessionID: String, params: ToolingJSONValue) {
        guard let entry = running[pluginID], entry.hostSessionID == sessionID,
              entry.hostServices.contains("lithe/host/run/start") else { return }
        notify(pluginID: pluginID, method: "lithe/host/run/didExit", params: params)
    }
}
