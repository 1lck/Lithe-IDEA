import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件后端的宿主服务分发、错误分类与订阅回收的决策见 .agents/notes/implemented/architecture/2026-10-30-plugin-backend-workspace-context.md

/// Starts plugin backends on their activation events (`backend` 2).
@MainActor
protocol PluginBackendActivating: AnyObject {
    /// Returns at once; the backends start in the background. `owner`
    /// limits `onCommand:<id>` to the plugin whose UI module declares it.
    func activate(event: String, owner: ModuleID?)
    /// The user ran one of the owner plugin's commands: its `backend` 2
    /// starts when it declares `onCommand:<id>`, and the running backend
    /// receives `lithe/host/commands/didRun` with the window's context.
    /// A command run from a Run marker also carries `runMarker` and starts
    /// the backend on `onLanguage:<languageID>`.
    func runCommand(
        _ commandID: String, owner: ModuleID, context: PluginWorkspaceContextReference?,
        runMarker: PluginRunMarkerInvocation?
    )
}

/// How a host service failed, as a function protocol 3 backend sees it.
/// Core passes these codes on; any other reaches the backend as
/// `plugin.host.failed`, and a protocol 2 backend sees `failed` for all.
enum PluginHostErrorCode: String, Sendable, CaseIterable {
    /// No service, or no method of it, on this host or for this authority.
    case unavailable = "plugin.host.unavailable"
    /// The plugin is not authorized for the service or this resource.
    case permissionDenied = "plugin.host.permissionDenied"
    /// The context named is closed or of an older generation.
    case contextExpired = "plugin.host.contextExpired"
    /// The context's authority is one this service does not implement.
    case authorityUnsupported = "plugin.host.authorityUnsupported"
    /// The resource changed since the version the request named.
    case versionConflict = "plugin.host.versionConflict"
    case invalidParams = "plugin.host.invalidParams"
    /// Too large or too many; too often is `.rateLimited`.
    case limitExceeded = "plugin.host.limitExceeded"
    /// The resource the request names does not exist.
    case notFound = "plugin.host.notFound"
    /// The resource exists but may not be written.
    case readOnly = "plugin.host.readOnly"
    /// The method exists but this host does not support an option it got.
    case unsupportedOption = "plugin.host.unsupportedOption"
    /// A state the operation needs does not hold, such as a missing parent
    /// directory or a resource that already exists.
    case preconditionFailed = "plugin.host.preconditionFailed"
    /// The host cannot serve the request right now; the same request may
    /// succeed when retried later.
    case busy = "plugin.host.busy"
    /// The plugin sent requests of this kind too often.
    case rateLimited = "plugin.host.rateLimited"
    case cancelled = "plugin.host.cancelled"
    case timeout = "plugin.host.timeout"
    /// The backend went away while the host worked on its request.
    case backendExited = "plugin.backend.exited"
    case failed = "plugin.host.failed"
}

/// A failed host service request. The message reaches the backend, so it
/// never carries a secret or a path the plugin may not see.
struct PluginHostServiceError: Error, Equatable, Sendable {
    let code: PluginHostErrorCode
    let message: String
    /// Facts the backend may act on, such as `{ currentVersion }` of a
    /// version conflict. The same rule as the message applies.
    let details: [String: ToolingJSONValue]?

    init(_ code: PluginHostErrorCode, _ message: String, details: [String: ToolingJSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    var failure: PluginHostRequestFailure {
        PluginHostRequestFailure(message: message, code: code.rawValue, details: details.map { .object($0) })
    }
}

/// One host request a service answers. Core has already checked the
/// method, the grant, and the shape of the params; the dispatcher has
/// resolved the context the params name, so `context` is current.
struct PluginHostCall {
    let pluginID: String
    let sessionID: String
    let request: PluginHostRequest
    /// The current context the params named under `context`; nil when they
    /// name none.
    let context: PluginWorkspaceContext?
    let params: [String: ToolingJSONValue]
    /// Where a service records what it must stop when the session ends or
    /// the context closes.
    let subscriptions: PluginHostSubscriptions
}

/// A host service plugin backends reach through `lithe/host/<service>/*`.
/// Each slice of the plugin API registers one with the dispatcher; it
/// answers only for the plugin in the call and refuses a context whose
/// authority it does not implement with `.authorityUnsupported`, never
/// acting on the local placeholder of a remote workspace.
@MainActor
protocol PluginHostServiceHandling: AnyObject {
    /// The service name of the methods, such as `workspace`.
    var service: String { get }
    var methods: Set<String> { get }
    /// Blocking work belongs off the main actor. A cancelled task's result
    /// is dropped: the backend was already answered.
    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError>
    func endSession(pluginID: String, sessionID: String)
    func closeContext(_ contextID: String)
}

extension PluginHostServiceHandling {
    var methods: Set<String> {
        switch service {
        case "credentials": Set(["get", "set", "delete"].map { "lithe/host/credentials/\($0)" })
        case "workspace": Set(["listContexts", "getContext", "getFolders"].map { "lithe/host/workspace/\($0)" })
        default: []
        }
    }
    func endSession(pluginID: String, sessionID: String) {}
    func closeContext(_ contextID: String) {}
}

/// Subscriptions services created for backends. Each belongs to one plugin
/// and possibly one context; ending the session, disabling the plugin,
/// `lithe/host/subscriptions/dispose`, or closing the context disposes it.
@MainActor
final class PluginHostSubscriptions {
    private struct Entry {
        let contextID: String?
        let dispose: @MainActor () -> Void
    }

    private var entries: [String: [String: Entry]] = [:]
    private var sequences: [String: Int] = [:]
    private var nextNumber = 1
    /// Sends `lithe/host/subscriptions/notify` to the plugin's backend.
    var deliver: (@MainActor (_ pluginID: String, _ params: ToolingJSONValue) -> Void)?

    /// Sends one event of a live subscription to its backend, with the next
    /// sequence number of that subscription. An event of a disposed
    /// subscription is dropped.
    func notify(pluginID: String, subscriptionID: String, event: [String: ToolingJSONValue]) {
        guard entries[pluginID]?[subscriptionID] != nil else { return }
        let sequence = (sequences[subscriptionID] ?? 0) + 1
        sequences[subscriptionID] = sequence
        deliver?(pluginID, .object([
            "subscriptionID": .string(subscriptionID),
            "sequence": .integer(sequence),
            "event": .object(event),
        ]))
    }

    func contains(pluginID: String, subscriptionID: String) -> Bool {
        entries[pluginID]?[subscriptionID] != nil
    }

    /// Records a subscription and returns its ID for the backend.
    func add(pluginID: String, contextID: String?, dispose: @escaping @MainActor () -> Void) -> String {
        let id = "s-\(nextNumber)"
        nextNumber += 1
        entries[pluginID, default: [:]][id] = Entry(contextID: contextID, dispose: dispose)
        return id
    }

    func count(pluginID: String) -> Int {
        entries[pluginID]?.count ?? 0
    }

    /// Unknown and already disposed IDs succeed, as the contract says.
    func dispose(pluginID: String, subscriptionID: String) {
        guard let entry = entries[pluginID]?.removeValue(forKey: subscriptionID) else { return }
        sequences[subscriptionID] = nil
        entry.dispose()
    }

    func disposeAll(pluginID: String) {
        guard let removed = entries.removeValue(forKey: pluginID) else { return }
        for (id, entry) in removed {
            sequences[id] = nil
            entry.dispose()
        }
    }

    func disposeAll(contextID: String) {
        for pluginID in Array(entries.keys) {
            guard let owned = entries[pluginID] else { continue }
            for (id, entry) in owned where entry.contextID == contextID {
                entries[pluginID]?[id] = nil
                sequences[id] = nil
                entry.dispose()
            }
        }
    }
}

/// Routes the host requests of plugin backends to the services registered
/// here. A request is handled for the plugin whose session sent it, inside
/// the context its params name and only for the services that session was
/// granted; Core checked the same, and this is the host's own check.
@MainActor
final class PluginHostServiceDispatcher {
    /// Services every plugin-owned session may call without a grant.
    /// `commands` has no methods: its notification brings the plugin's own
    /// commands to its backend.
    static let implicitServices: Set<String> = ["host", "subscriptions", "commands"]

    let contexts: PluginWorkspaceContexts
    let subscriptions = PluginHostSubscriptions()
    private var handlers: [String: any PluginHostServiceHandling] = [:]
    private var grants: [String: Set<String>] = [:]
    private var sessionIDs: [String: String] = [:]
    private struct Pending {
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>?
        let contextID: String?
        let respond: @MainActor (Result<ToolingJSONValue, PluginHostRequestFailure>) -> Void
    }
    private var inFlight: [String: [String: Pending]] = [:]
    private var contextObserver: UUID?

    init(contexts: PluginWorkspaceContexts) {
        self.contexts = contexts
        contextObserver = contexts.observeClose { [weak self] contextID in
            guard let self else { return }
            self.subscriptions.disposeAll(contextID: contextID)
            for handler in self.uniqueHandlers { handler.closeContext(contextID) }
            for (plugin, requests) in self.inFlight {
                for (id, pending) in requests where pending.contextID == contextID {
                    self.inFlight[plugin]?[id] = nil
                    pending.task.cancel()
                    pending.deadline?.cancel()
                    pending.respond(.failure(PluginHostServiceError(.contextExpired,
                        L10n.string("The workspace context is no longer current. Ask the host for it again.")).failure))
                }
            }
        }
    }

    /// Registers exact methods; duplicate ownership is a composition error.
    func register(_ handler: any PluginHostServiceHandling) {
        for method in handler.methods {
            precondition(handlers[method] == nil, "Duplicate plugin host method")
            handlers[method] = handler
        }
    }

    private var uniqueHandlers: [any PluginHostServiceHandling] {
        var seen: Set<ObjectIdentifier> = []
        return handlers.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    var registeredServices: [String] {
        Array(Set(uniqueHandlers.map(\.service))).sorted()
    }

    func supportedGrants(_ requested: [String]) -> [String] {
        requested.filter { grant in
            if handlers[grant] != nil { return true }
            let legacy: [String]
            switch grant {
            case "workspace": legacy = ["listContexts", "getContext", "getFolders"]
            case "credentials": legacy = ["get", "set", "delete"]
            default: return false
            }
            return legacy.allSatisfy { handlers["lithe/host/\(grant)/\($0)"] != nil }
        }
    }

    /// Starts serving a session with the host services it was granted.
    @discardableResult
    func beginSession(pluginID: String, hostServices: [String]) -> String {
        endSession(pluginID: pluginID)
        let id = UUID().uuidString
        sessionIDs[pluginID] = id
        grants[pluginID] = Set(hostServices)
        return id
    }

    /// Ends serving a session: the work in flight stops unanswered and its
    /// subscriptions are disposed.
    func endSession(pluginID: String) {
        grants[pluginID] = nil
        if let id = sessionIDs.removeValue(forKey: pluginID) {
            for handler in uniqueHandlers { handler.endSession(pluginID: pluginID, sessionID: id) }
        }
        if let tasks = inFlight.removeValue(forKey: pluginID) {
            for pending in tasks.values { pending.task.cancel(); pending.deadline?.cancel() }
        }
        subscriptions.disposeAll(pluginID: pluginID)
    }

    /// Answers a request through `respond`, unless the backend cancels it
    /// first (`cancel`) or the session ends.
    func handle(
        _ request: PluginHostRequest,
        pluginID: String,
        sessionID: String? = nil,
        respond: @escaping @MainActor (Result<ToolingJSONValue, PluginHostRequestFailure>) -> Void
    ) {
        guard let currentSession = sessionIDs[pluginID], sessionID == nil || sessionID == currentSession else { return }
        guard inFlight[pluginID]?[request.id] == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.sessionIDs[pluginID] == currentSession else { return }
            let outcome = await self.dispatch(request, pluginID: pluginID)
            guard !Task.isCancelled, self.sessionIDs[pluginID] == currentSession,
                  let pending = self.inFlight[pluginID]?.removeValue(forKey: request.id) else { return }
            pending.deadline?.cancel()
            respond(outcome)
        }
        let contextID: String?
        if case .object(let params) = request.params, let value = params["context"] {
            contextID = Self.contextReference(value)?.contextID
        } else { contextID = nil }
        // User-choice messages have no clock deadline; their session, context
        // and cancellation own dismissal. Machine operations are locally bounded.
        let deadline: Task<Void, Never>? = request.method.hasPrefix("lithe/host/window/show") ? nil : Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.sessionIDs[pluginID] == currentSession,
                  let pending = self.inFlight[pluginID]?.removeValue(forKey: request.id) else { return }
            pending.task.cancel()
            pending.respond(.failure(PluginHostServiceError(.timeout,
                L10n.string("The plugin host request could not be completed.")).failure))
        }
        inFlight[pluginID, default: [:]][request.id] = Pending(task: task, deadline: deadline, contextID: contextID, respond: respond)
    }

    /// The backend cancelled the request; Core already answered it.
    func cancel(hostRequestID: String, pluginID: String, sessionID: String? = nil) {
        guard sessionID == nil || sessionIDs[pluginID] == sessionID else { return }
        if let pending = inFlight[pluginID]?.removeValue(forKey: hostRequestID) {
            pending.task.cancel()
            pending.deadline?.cancel()
        }
    }

    func dispatch(_ request: PluginHostRequest, pluginID: String) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        guard let granted = grants[pluginID], let sessionID = sessionIDs[pluginID] else {
            return .failure(PluginHostServiceError(
                .backendExited, L10n.string("The plugin backend is no longer running.")
            ).failure)
        }
        let legacyMethod = request.method.hasPrefix("lithe/host/credentials/")
            || ["listContexts", "getContext", "getFolders"].map { "lithe/host/workspace/" + $0 }.contains(request.method)
        guard Self.implicitServices.contains(request.service) || granted.contains(request.method)
                || (legacyMethod && granted.contains(request.service)) else {
            return .failure(PluginHostServiceError(
                .permissionDenied, L10n.string("The plugin is not allowed to use the host service \(request.service).")
            ).failure)
        }
        let params: [String: ToolingJSONValue]
        switch request.params {
        case .object(let object): params = object
        case .null: params = [:]
        default:
            return .failure(PluginHostServiceError(
                .invalidParams, L10n.string("The params of \(request.method) must be an object.")
            ).failure)
        }
        if request.method == "lithe/host/subscriptions/dispose" {
            guard case .string(let id)? = params["subscriptionID"] else {
                return .failure(PluginHostServiceError(
                    .invalidParams, L10n.string("The params of \(request.method) must name a subscriptionID.")
                ).failure)
            }
            subscriptions.dispose(pluginID: pluginID, subscriptionID: id)
            return .success(.null)
        }
        var context: PluginWorkspaceContext?
        if let value = params["context"] {
            guard let reference = Self.contextReference(value) else {
                return .failure(PluginHostServiceError(
                    .invalidParams, L10n.string("The workspace context reference is malformed.")
                ).failure)
            }
            switch contexts.resolve(reference) {
            case .success(let current): context = current
            case .failure(let error): return .failure(error.failure)
            }
        }
        guard let handler = handlers[request.method] else {
            return .failure(PluginHostServiceError(
                .unavailable, L10n.string("The host does not serve \(request.method).")
            ).failure)
        }
        let call = PluginHostCall(
            pluginID: pluginID, sessionID: sessionID, request: request, context: context, params: params, subscriptions: subscriptions
        )
        return await handler.answer(call).mapError(\.failure)
    }

    static func contextReference(_ value: ToolingJSONValue) -> PluginWorkspaceContextReference? {
        guard case .object(let object) = value, object.count == 2,
              case .string(let id)? = object["contextID"], !id.isEmpty,
              case .integer(let generation)? = object["generation"], generation >= 1 else {
            return nil
        }
        return PluginWorkspaceContextReference(contextID: id, generation: generation)
    }
}

/// `credentials`: the secrets of function protocol 2, unchanged. Keychain
/// calls block, so they run off the main actor.
@MainActor
final class PluginCredentialHostService: PluginHostServiceHandling {
    let service = "credentials"
    private let credentials: any PluginCredentialStoring

    init(credentials: any PluginCredentialStoring) {
        self.credentials = credentials
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        let credentials = credentials
        let request = call.request
        let pluginID = call.pluginID
        let outcome = await Task.detached(priority: .userInitiated) {
            PluginHostServices.answer(request, pluginID: pluginID, credentials: credentials)
        }.value
        return outcome.mapError { PluginHostServiceError(.failed, $0.message) }
    }
}

/// `workspace`: the contexts a backend works in (`workspace.metadata`).
/// Paths appear only for a local authority. A context's state directory is
/// private to the plugin, outside the bundle, and created by `getContext`
/// only: listing the contexts creates nothing, so a backend that never
/// works in a workspace leaves no directory for it.
@MainActor
final class PluginWorkspaceHostService: PluginHostServiceHandling {
    let service = "workspace"
    private let contexts: PluginWorkspaceContexts
    private let backendStateDirectory: (String) -> URL
    private let rootIDSecret: () -> Data
    private lazy var rootIDs = PluginWorkspaceRootIDs(secret: rootIDSecret())
    private let fileManager: FileManager

    /// `backendStateDirectory` gives a plugin's `${stateDir}`, which must be
    /// a platform-writable directory; context state lives below it.
    /// `rootIDSecret` is read once, for the first described folder; it must
    /// stay the same across launches for root IDs to stay stable.
    init(
        contexts: PluginWorkspaceContexts,
        backendStateDirectory: @escaping (String) -> URL,
        rootIDSecret: @escaping () -> Data,
        fileManager: FileManager = .default
    ) {
        self.contexts = contexts
        self.backendStateDirectory = backendStateDirectory
        self.rootIDSecret = rootIDSecret
        self.fileManager = fileManager
    }

    func rootID(of folder: PluginWorkspaceContext.Folder, pluginID: String) -> String {
        rootIDs.rootID(of: folder.location, pluginID: pluginID)
    }

    func stateDirectory(of context: PluginWorkspaceContext, pluginID: String) -> URL {
        backendStateDirectory(pluginID)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(PluginWorkspaceContexts.stateDigest(context.stateKey), isDirectory: true)
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        switch call.request.method {
        case "lithe/host/workspace/listContexts":
            let described = contexts.contexts.map { describe($0, pluginID: call.pluginID) }
            return .success(.object([
                "revision": .integer(contexts.revision),
                "contexts": .array(described.map { .object($0) }),
            ]))
        case "lithe/host/workspace/getContext":
            guard let context = call.context else { return .failure(Self.missingContext) }
            let directory = stateDirectory(of: context, pluginID: call.pluginID)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return .failure(PluginHostServiceError(
                    .failed, L10n.string("The host could not create the plugin's workspace state directory.")
                ))
            }
            var object = describe(context, pluginID: call.pluginID)
            object["stateDirectory"] = .string(directory.path)
            return .success(.object(object))
        case "lithe/host/workspace/getFolders":
            guard let context = call.context else { return .failure(Self.missingContext) }
            return .success(.object(["folders": .array(context.folders.map {
                describe($0, authority: context.authority, pluginID: call.pluginID)
            })]))
        default:
            return .failure(PluginHostServiceError(
                .unavailable, L10n.string("The host does not serve \(call.request.method).")
            ))
        }
    }

    private static var missingContext: PluginHostServiceError {
        PluginHostServiceError(.invalidParams, L10n.string("The workspace context reference is malformed."))
    }

    /// A context without its state directory, which only `getContext` gives.
    private func describe(_ context: PluginWorkspaceContext, pluginID: String) -> [String: ToolingJSONValue] {
        let authority: [String: ToolingJSONValue]
        switch context.authority {
        case .local: authority = ["kind": .string("local")]
        case .remote(let id): authority = ["kind": .string("remote"), "id": .string(id)]
        }
        return [
            "contextID": .string(context.contextID),
            "generation": .integer(context.generation),
            "name": .string(context.name),
            "authority": .object(authority),
            "folders": .array(context.folders.map { describe($0, authority: context.authority, pluginID: pluginID) }),
        ]
    }

    private func describe(
        _ folder: PluginWorkspaceContext.Folder,
        authority: PluginWorkspaceContext.Authority,
        pluginID: String
    ) -> ToolingJSONValue {
        var object: [String: ToolingJSONValue] = [
            "rootID": .string(rootID(of: folder, pluginID: pluginID)),
            "name": .string(folder.name),
        ]
        // The local directory of a remote workspace is a placeholder.
        if authority == .local { object["path"] = .string(folder.localURL.path) }
        return .object(object)
    }
}
