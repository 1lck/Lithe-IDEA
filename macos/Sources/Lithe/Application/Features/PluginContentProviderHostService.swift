import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件自有语言服务器会话与宿主方法的决策见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

/// One URI scheme a plugin backend serves in one workspace window.
struct PluginContentProviderRegistration: Equatable {
    let lease: UUID
    let pluginID: String
    let sessionID: String
    let context: PluginWorkspaceContextReference
    let scheme: String
    let functionID: String
}

/// `lithe/host/documents/registerContentProvider` (plan API-12): a plugin
/// backend serves the read-only text of documents that have no file, such as
/// the source of a library class its language server decompiles.
///
/// Registration only records the binding; it never calls the backend while
/// the backend awaits this answer. The scheme's grammar and reserved names
/// are checked by Rust Core before the request reaches the service. The
/// provider belongs to the backend session and the window: ending the
/// session, closing the context, disposing the subscription, or withdrawing
/// the function removes it.
@MainActor
final class PluginContentProviderHostService: PluginHostServiceHandling {
    let service = "documents"
    let methods: Set<String> = ["lithe/host/documents/registerContentProvider"]
    private let contexts: PluginWorkspaceContexts
    private let decoder: any PluginContentDecoding
    private var providers: [UUID: PluginContentProviderRegistration] = [:]
    private var withdrawals: [UUID: @MainActor () -> Void] = [:]
    /// The functions each backend session has registered; a provider needs one.
    private var functions: [String: (session: String, ids: Set<String>)] = [:]

    init(contexts: PluginWorkspaceContexts, decoder: any PluginContentDecoding) {
        self.contexts = contexts
        self.decoder = decoder
    }

    /// The provider that serves `scheme` in the window, if one is registered.
    func provider(forScheme scheme: String, context: PluginWorkspaceContextReference) -> PluginContentProviderRegistration? {
        providers.values.first { $0.scheme == scheme && $0.context == context }
    }

    /// The document text of a provider's answer, or the reason Core refused it.
    func content(of answer: ToolingJSONValue) throws -> String {
        try decoder.decodeContent(answer)
    }

    // MARK: Registration

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            let arguments = try PluginHostArguments(call.params, allowed: ["context", "scheme", "function"])
            let scheme = try arguments.string("scheme")
            let functionID = try arguments.string("function")
            guard functions[call.pluginID]?.session == call.sessionID,
                  functions[call.pluginID]?.ids.contains(functionID) == true else {
                throw PluginHostArguments.invalid
            }
            guard provider(forScheme: scheme, context: scope.workspace.reference) == nil else {
                throw PluginHostServiceError(.preconditionFailed, L10n.string("This content scheme already has a provider."))
            }
            let registration = PluginContentProviderRegistration(
                lease: UUID(), pluginID: call.pluginID, sessionID: call.sessionID,
                context: scope.workspace.reference, scheme: scheme, functionID: functionID
            )
            return .success(.object(["subscriptionID": .string(add(registration, to: call.subscriptions))]))
        } catch {
            var failure = PluginHostAPIValues.failure(error)
            failure.logError = error
            return .failure(failure)
        }
    }

    /// Records the provider and returns the subscription that removes it.
    private func add(_ registration: PluginContentProviderRegistration, to subscriptions: PluginHostSubscriptions) -> String {
        let lease = registration.lease
        let subscriptionID = subscriptions.add(
            pluginID: registration.pluginID, contextID: registration.context.contextID
        ) { [weak self] in
            self?.providers[lease] = nil
            self?.withdrawals[lease] = nil
        }
        providers[lease] = registration
        let pluginID = registration.pluginID
        withdrawals[lease] = { [weak subscriptions] in
            subscriptions?.dispose(pluginID: pluginID, subscriptionID: subscriptionID)
        }
        return subscriptionID
    }

    // MARK: Lifecycle

    /// A withdrawn function takes its providers with it. Registering again
    /// is explicit; a reused function ID must not revive an old provider.
    func updateFunctions(pluginID: String, sessionID: String, ids: [String]) {
        let ids = Set(ids)
        let previous = functions[pluginID]
        functions[pluginID] = (sessionID, ids)
        let stillRegistered = previous.map { $0.session == sessionID && $0.ids.isSubset(of: ids) } ?? true
        if !stillRegistered { withdrawProviders(ofPlugin: pluginID) }
    }

    func endSession(pluginID: String, sessionID: String) {
        guard functions[pluginID]?.session == sessionID else { return }
        functions[pluginID] = nil
        withdrawProviders(ofPlugin: pluginID)
    }

    func closeContext(_ contextID: String) {
        for provider in Array(providers.values) where provider.context.contextID == contextID {
            withdrawals[provider.lease]?()
        }
    }

    private func withdrawProviders(ofPlugin pluginID: String) {
        for provider in Array(providers.values) where provider.pluginID == pluginID {
            withdrawals[provider.lease]?()
        }
    }
}
