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
    /// Too large, too many, or too often.
    case limitExceeded = "plugin.host.limitExceeded"
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

    init(_ code: PluginHostErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    var failure: PluginHostRequestFailure {
        PluginHostRequestFailure(message: message, code: code.rawValue)
    }
}

/// One host request a service answers. Core has already checked the
/// method, the grant, and the shape of the params; the dispatcher has
/// resolved the context the params name, so `context` is current.
struct PluginHostCall {
    let pluginID: String
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
    /// Blocking work belongs off the main actor. A cancelled task's result
    /// is dropped: the backend was already answered.
    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError>
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
    private var nextNumber = 1

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
        entries[pluginID]?.removeValue(forKey: subscriptionID)?.dispose()
    }

    func disposeAll(pluginID: String) {
        guard let removed = entries.removeValue(forKey: pluginID) else { return }
        for entry in removed.values { entry.dispose() }
    }

    func disposeAll(contextID: String) {
        for pluginID in Array(entries.keys) {
            guard let owned = entries[pluginID] else { continue }
            for (id, entry) in owned where entry.contextID == contextID {
                entries[pluginID]?[id] = nil
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
    static let implicitServices: Set<String> = ["host", "subscriptions"]

    let contexts: PluginWorkspaceContexts
    let subscriptions = PluginHostSubscriptions()
    private var handlers: [String: any PluginHostServiceHandling] = [:]
    private var grants: [String: Set<String>] = [:]
    private var inFlight: [String: [String: Task<Void, Never>]] = [:]
    private var contextObserver: UUID?

    init(contexts: PluginWorkspaceContexts) {
        self.contexts = contexts
        contextObserver = contexts.observeClose { [weak self] contextID in
            self?.subscriptions.disposeAll(contextID: contextID)
        }
    }

    /// Adds or replaces the handler of its service.
    func register(_ handler: any PluginHostServiceHandling) {
        handlers[handler.service] = handler
    }

    var registeredServices: [String] {
        handlers.keys.sorted()
    }

    /// Starts serving a session with the host services it was granted.
    func beginSession(pluginID: String, hostServices: [String]) {
        grants[pluginID] = Set(hostServices)
    }

    /// Ends serving a session: the work in flight stops unanswered and its
    /// subscriptions are disposed.
    func endSession(pluginID: String) {
        grants[pluginID] = nil
        if let tasks = inFlight.removeValue(forKey: pluginID) {
            for task in tasks.values { task.cancel() }
        }
        subscriptions.disposeAll(pluginID: pluginID)
    }

    /// Answers a request through `respond`, unless the backend cancels it
    /// first (`cancel`) or the session ends.
    func handle(
        _ request: PluginHostRequest,
        pluginID: String,
        respond: @escaping @MainActor (Result<ToolingJSONValue, PluginHostRequestFailure>) -> Void
    ) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.dispatch(request, pluginID: pluginID)
            guard !Task.isCancelled, self.inFlight[pluginID]?.removeValue(forKey: request.id) != nil else { return }
            respond(outcome)
        }
        inFlight[pluginID, default: [:]][request.id] = task
    }

    /// The backend cancelled the request; Core already answered it.
    func cancel(hostRequestID: String, pluginID: String) {
        inFlight[pluginID]?.removeValue(forKey: hostRequestID)?.cancel()
    }

    func dispatch(_ request: PluginHostRequest, pluginID: String) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        guard let granted = grants[pluginID] else {
            return .failure(PluginHostServiceError(
                .backendExited, L10n.string("The plugin backend is no longer running.")
            ).failure)
        }
        guard Self.implicitServices.contains(request.service) || granted.contains(request.service) else {
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
                    .invalidParams, L10n.string("The params of \(request.method) must be an object.")
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
        guard let handler = handlers[request.service] else {
            return .failure(PluginHostServiceError(
                .unavailable, L10n.string("The host does not serve \(request.method).")
            ).failure)
        }
        let call = PluginHostCall(
            pluginID: pluginID, request: request, context: context, params: params, subscriptions: subscriptions
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
/// Paths appear only for a local authority; a context's state directory is
/// private to the plugin and created on first use, outside the bundle.
@MainActor
final class PluginWorkspaceHostService: PluginHostServiceHandling {
    let service = "workspace"
    private let contexts: PluginWorkspaceContexts
    private let backendStateDirectory: (String) -> URL
    private let fileManager: FileManager

    /// `backendStateDirectory` gives a plugin's `${stateDir}`, which must be
    /// a platform-writable directory; context state lives below it.
    init(
        contexts: PluginWorkspaceContexts,
        backendStateDirectory: @escaping (String) -> URL,
        fileManager: FileManager = .default
    ) {
        self.contexts = contexts
        self.backendStateDirectory = backendStateDirectory
        self.fileManager = fileManager
    }

    func stateDirectory(of context: PluginWorkspaceContext, pluginID: String) -> URL {
        backendStateDirectory(pluginID)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(PluginWorkspaceContexts.stateDigest(context.stateKey), isDirectory: true)
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        switch call.request.method {
        case "lithe/host/workspace/listContexts":
            var described: [ToolingJSONValue] = []
            for context in contexts.contexts {
                switch describe(context, pluginID: call.pluginID) {
                case .success(let value): described.append(value)
                case .failure(let error): return .failure(error)
                }
            }
            return .success(.object(["revision": .integer(contexts.revision), "contexts": .array(described)]))
        case "lithe/host/workspace/getContext":
            guard let context = call.context else { return .failure(Self.missingContext) }
            return describe(context, pluginID: call.pluginID)
        case "lithe/host/workspace/getFolders":
            guard let context = call.context else { return .failure(Self.missingContext) }
            return .success(.object(["folders": .array(context.folders.map { Self.describe($0, authority: context.authority) })]))
        default:
            return .failure(PluginHostServiceError(
                .unavailable, L10n.string("The host does not serve \(call.request.method).")
            ))
        }
    }

    private static var missingContext: PluginHostServiceError {
        PluginHostServiceError(.invalidParams, L10n.string("The workspace context reference is malformed."))
    }

    private func describe(_ context: PluginWorkspaceContext, pluginID: String) -> Result<ToolingJSONValue, PluginHostServiceError> {
        let directory = stateDirectory(of: context, pluginID: pluginID)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(PluginHostServiceError(
                .failed, L10n.string("The host could not create the plugin's workspace state directory.")
            ))
        }
        let authority: [String: ToolingJSONValue]
        switch context.authority {
        case .local: authority = ["kind": .string("local")]
        case .remote(let id): authority = ["kind": .string("remote"), "id": .string(id)]
        }
        return .success(.object([
            "contextID": .string(context.contextID),
            "generation": .integer(context.generation),
            "name": .string(context.name),
            "authority": .object(authority),
            "folders": .array(context.folders.map { Self.describe($0, authority: context.authority) }),
            "stateDirectory": .string(directory.path),
        ]))
    }

    private static func describe(
        _ folder: PluginWorkspaceContext.Folder,
        authority: PluginWorkspaceContext.Authority
    ) -> ToolingJSONValue {
        var object: [String: ToolingJSONValue] = ["rootID": .string(folder.rootID), "name": .string(folder.name)]
        // The local directory of a remote workspace is a placeholder.
        if authority == .local { object["path"] = .string(folder.localURL.path) }
        return .object(object)
    }
}
