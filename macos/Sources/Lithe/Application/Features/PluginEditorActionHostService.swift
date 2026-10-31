import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 独立扩展点与领域契约的边界见 .agents/notes/implemented/architecture/2026-10-31-plugin-capability-and-domain-boundaries.md

/// One total collection budget, below the editor bridge's ten-second deadline.
enum PluginEditorActionCollectionBudget {
    static let maximum: Duration = .seconds(8)

    static func remaining(after elapsed: Duration) -> Duration? {
        let remaining = maximum - elapsed
        return remaining > .zero ? remaining : nil
    }
}

/// A context/session-owned binding, not a language, Build or Run provider.
struct PluginEditorActionRegistration: Equatable {
    let lease: UUID
    let pluginID: String
    let sessionID: String
    let context: PluginWorkspaceContextReference
    let id: String
    let functionID: String
    let fileExtensions: [String]
    let fileNames: [String]

    func matches(_ filename: String) -> Bool {
        let filename = filename.lowercased()
        return fileNames.contains(filename) || fileExtensions.contains { filename.hasSuffix("." + $0) }
    }
}

/// Registration only changes a binding. It never calls a backend while the
/// backend is awaiting this host response; collection happens in a later turn.
@MainActor
final class PluginEditorActionHostService: PluginHostServiceHandling {
    let service = "editor"
    let methods: Set<String> = ["lithe/host/editor/registerActions"]
    private let contexts: PluginWorkspaceContexts
    private let decoder: any PluginEditorActionDecoding
    private let changed = PassthroughSubject<Void, Never>()
    private var entries: [UUID: PluginEditorActionRegistration] = [:]
    private var disposeRegistration: [UUID: @MainActor () -> Void] = [:]
    private var functions: [String: (session: String, ids: Set<String>)] = [:]

    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }

    init(contexts: PluginWorkspaceContexts, decoder: any PluginEditorActionDecoding) {
        self.contexts = contexts
        self.decoder = decoder
    }

    func registrations(context: PluginWorkspaceContextReference, filename: String) -> [PluginEditorActionRegistration] {
        entries.values.filter { $0.context == context && $0.matches(filename) }
            .sorted { ($0.pluginID, $0.id) < ($1.pluginID, $1.id) }
    }

    func contains(_ registration: PluginEditorActionRegistration, functionID: String? = nil) -> Bool {
        entries[registration.lease] == registration
            && functions[registration.pluginID]?.session == registration.sessionID
            && functions[registration.pluginID]?.ids.contains(functionID ?? registration.functionID) == true
    }

    /// Function withdrawal invalidates the complete binding. Register it again
    /// explicitly; a reused function ID must not resurrect old document actions.
    func updateFunctions(pluginID: String, sessionID: String, ids: [String]) {
        let ids = Set(ids)
        guard functions[pluginID]?.session != sessionID || functions[pluginID]?.ids != ids else { return }
        let previous = functions[pluginID]
        functions[pluginID] = (sessionID, ids)
        let revoked = previous?.session != sessionID || !(previous?.ids ?? []).isSubset(of: ids)
        guard revoked else { return }
        for entry in Array(entries.values) where entry.pluginID == pluginID {
            disposeRegistration[entry.lease]?()
        }
        changed.send()
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            let args = try PluginHostArguments(call.params, allowed: ["context", "id", "function", "selector"])
            let input: ToolingJSONValue = .object([
                "id": .string(try args.string("id")), "function": .string(try args.string("function")),
                "selector": .object(try args.object("selector")),
            ])
            let normalized: ToolingJSONValue
            do { normalized = try decoder.decodeEditorActions(kind: "registration", value: input, text: "") }
            catch { throw PluginHostArguments.invalid }
            guard case .object(let result) = normalized, case .object(let value)? = result["registration"],
                  case .string(let id)? = value["id"], case .string(let functionID)? = value["function"],
                  case .object(let selector)? = value["selector"],
                  case .array(let extensions)? = selector["fileExtensions"], case .array(let names)? = selector["fileNames"],
                  functions[call.pluginID]?.session == call.sessionID,
                  functions[call.pluginID]?.ids.contains(functionID) == true else { throw PluginHostArguments.invalid }
            guard entries.values.filter({ $0.pluginID == call.pluginID }).count < 32 else {
                throw PluginHostServiceError(.limitExceeded, L10n.string("The plugin host request could not be completed."))
            }
            guard !entries.values.contains(where: { $0.pluginID == call.pluginID && $0.context == scope.workspace.reference && $0.id == id }) else {
                throw PluginHostServiceError(.preconditionFailed, L10n.string("The plugin host request parameters are invalid."))
            }
            let lease = UUID()
            let registration = PluginEditorActionRegistration(
                lease: lease, pluginID: call.pluginID, sessionID: call.sessionID, context: scope.workspace.reference,
                id: id, functionID: functionID,
                fileExtensions: extensions.compactMap { if case .string(let text) = $0 { text } else { nil } },
                fileNames: names.compactMap { if case .string(let text) = $0 { text } else { nil } }
            )
            let subscription = call.subscriptions.add(pluginID: call.pluginID, contextID: scope.workspace.reference.contextID) { [weak self] in
                self?.disposeRegistration[lease] = nil
                guard self?.entries.removeValue(forKey: lease) != nil else { return }
                self?.changed.send()
            }
            entries[lease] = registration
            let pluginID = call.pluginID
            disposeRegistration[lease] = { [weak subscriptions = call.subscriptions] in
                subscriptions?.dispose(pluginID: pluginID, subscriptionID: subscription)
            }
            changed.send()
            return .success(.object(["subscriptionID": .string(subscription)]))
        } catch { return .failure(PluginHostAPIValues.failure(error)) }
    }

    func decode(_ result: ToolingJSONValue, text: String) throws -> [PluginEditorAction] {
        let value = try decoder.decodeEditorActions(kind: "actions", value: result, text: text)
        struct Response: Decodable { let actions: [PluginEditorAction] }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value)).actions
    }

    func endSession(pluginID: String, sessionID: String) {
        guard functions[pluginID]?.session == sessionID else { return }
        functions[pluginID] = nil
        for entry in Array(entries.values) where entry.pluginID == pluginID {
            disposeRegistration[entry.lease]?()
        }
        changed.send()
    }

    func closeContext(_ contextID: String) {
        for entry in Array(entries.values) where entry.context.contextID == contextID {
            disposeRegistration[entry.lease]?()
        }
    }
}
