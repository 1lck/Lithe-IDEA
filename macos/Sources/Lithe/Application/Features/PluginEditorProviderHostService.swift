import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 编辑器 Provider 与语言服务器的合并取舍见 .agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md

/// A context/session-owned binding of editor language-feature functions to a
/// file selector. It is not a language, Build or Run provider: a language
/// server answers first and a registration only adds to it.
struct PluginEditorProviderRegistration: Equatable {
    /// One provider entry; `budget` is Core's per-type answer deadline.
    struct Provider: Equatable {
        let functionID: String
        let budget: Duration
        let triggerCharacters: [String]
        let legend: ToolingJSONValue?
    }

    let lease: UUID
    let pluginID: String
    let sessionID: String
    let context: PluginWorkspaceContextReference
    let id: String
    let languages: [String]
    let fileExtensions: [String]
    let fileNames: [String]
    let providers: [String: Provider]

    /// Selector entries are lowercased literals; any matching entry selects the file.
    func matches(filename: String, language: String) -> Bool {
        let filename = filename.lowercased()
        return languages.contains(language.lowercased()) || fileNames.contains(filename)
            || fileExtensions.contains { filename.hasSuffix("." + $0) }
    }
}

/// The document one provider call is about. The plugin reads its text with
/// `documents/getSnapshot` and answers for exactly `version`.
struct PluginEditorProviderDocument {
    let documentID: String
    let version: UInt64
    let filename: String
    let language: String
}

/// One validated provider answer with the registration that produced it.
struct PluginEditorProviderAnswer {
    let registration: PluginEditorProviderRegistration
    let provider: PluginEditorProviderRegistration.Provider
    /// Core's normalized result for the provider type (`{locations}`, `{contents}`, ...).
    let result: ToolingJSONValue
}

/// Registration only changes a binding. It never calls a backend while the
/// backend is awaiting this host response; queries happen in a later turn.
@MainActor
final class PluginEditorProviderHostService: PluginHostServiceHandling {
    /// The largest document the plugin document service can snapshot.
    static let snapshotLimitBytes = 128 * 1024
    private static let registrationsPerPlugin = 32

    let service = "editor"
    let methods: Set<String> = ["lithe/host/editor/registerProviders"]
    private let contexts: PluginWorkspaceContexts
    private let decoder: any PluginEditorProviderDecoding
    private let providerTypes: [String]
    private let logSink: (any LogSink)?
    private let changed = PassthroughSubject<Void, Never>()
    private var entries: [UUID: PluginEditorProviderRegistration] = [:]
    private var disposeRegistration: [UUID: @MainActor () -> Void] = [:]
    private var functions: [String: (session: String, ids: Set<String>)] = [:]

    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }

    init(
        contexts: PluginWorkspaceContexts, decoder: any PluginEditorProviderDecoding,
        host: PluginEditorHostOptions, logSink: (any LogSink)? = nil
    ) {
        self.contexts = contexts
        self.decoder = decoder
        self.providerTypes = host.providerTypes
        self.logSink = logSink
    }

    /// Registrations of `context` whose selector matches the file and that provide `type`.
    func registrations(
        context: PluginWorkspaceContextReference, filename: String, language: String, type: String
    ) -> [PluginEditorProviderRegistration] {
        entries.values.filter {
            $0.context == context && $0.providers[type] != nil && $0.matches(filename: filename, language: language)
        }.sorted { ($0.pluginID, $0.id) < ($1.pluginID, $1.id) }
    }

    func contains(_ registration: PluginEditorProviderRegistration, functionID: String) -> Bool {
        entries[registration.lease] == registration
            && functions[registration.pluginID]?.session == registration.sessionID
            && functions[registration.pluginID]?.ids.contains(functionID) == true
    }

    /// Function withdrawal invalidates every registration of the plugin. A
    /// plugin registers again explicitly; a reused function ID must not
    /// resurrect an old binding.
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
            let args = try PluginHostArguments(call.params, allowed: ["context", "id", "selector", "providers"])
            let input: ToolingJSONValue = .object([
                "id": .string(try args.string("id")), "selector": .object(try args.object("selector")),
                "providers": .object(try args.object("providers")),
            ])
            let normalized: ToolingJSONValue
            do { normalized = try decoder.decodeEditorProviderRegistration(value: input, types: providerTypes) }
            catch let unsupported as PluginEditorProviderUnsupported {
                throw PluginHostServiceError(
                    .unsupportedOption, L10n.string("The host does not support the requested option yet."),
                    details: ["option": .string(unsupported.option)])
            } catch { throw PluginHostArguments.invalid }
            guard case .object(let result) = normalized, case .object(let value)? = result["registration"],
                  case .string(let id)? = value["id"], case .object(let selector)? = value["selector"],
                  case .object(let providers)? = value["providers"] else { throw PluginHostArguments.invalid }
            func names(_ key: String) -> [String] {
                guard case .array(let list)? = selector[key] else { return [] }
                return list.compactMap { if case .string(let text) = $0 { text } else { nil } }
            }
            var parsed: [String: PluginEditorProviderRegistration.Provider] = [:]
            for (type, entry) in providers {
                guard case .object(let object) = entry, case .string(let functionID)? = object["function"],
                      case .integer(let budget)? = object["budgetMs"],
                      functions[call.pluginID]?.session == call.sessionID,
                      functions[call.pluginID]?.ids.contains(functionID) == true else { throw PluginHostArguments.invalid }
                var triggers: [String] = []
                if case .array(let list)? = object["triggerCharacters"] {
                    triggers = list.compactMap { if case .string(let text) = $0 { text } else { nil } }
                }
                parsed[type] = .init(
                    functionID: functionID, budget: .milliseconds(budget), triggerCharacters: triggers,
                    legend: object["legend"])
            }
            guard entries.values.filter({ $0.pluginID == call.pluginID }).count < Self.registrationsPerPlugin else {
                throw PluginHostServiceError(.limitExceeded, L10n.string("The plugin host request could not be completed."))
            }
            guard !entries.values.contains(where: {
                $0.pluginID == call.pluginID && $0.context == scope.workspace.reference && $0.id == id
            }) else {
                throw PluginHostServiceError(.preconditionFailed, L10n.string("The plugin host request parameters are invalid."))
            }
            let lease = UUID()
            let registration = PluginEditorProviderRegistration(
                lease: lease, pluginID: call.pluginID, sessionID: call.sessionID, context: scope.workspace.reference,
                id: id, languages: names("languages"), fileExtensions: names("fileExtensions"),
                fileNames: names("fileNames"), providers: parsed)
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
        } catch {
            var failure = PluginHostAPIValues.failure(error)
            failure.logError = error
            return .failure(failure)
        }
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

    /// Core's definition merge of the language server's locations with the
    /// plugins'; returns the indices each side keeps.
    func mergeDefinitions(
        documentURL: URL, line: Int, character: Int, server: [ToolingJSONValue], plugin: [ToolingJSONValue]
    ) throws -> (server: [Int], plugin: [Int]) {
        try decoder.mergeEditorDefinitions(
            documentURI: documentURL.standardizedFileURL.absoluteString, line: line, character: character,
            server: server, plugin: plugin)
    }

    /// Calls every matching provider of `type` concurrently, each within the
    /// budget Core assigned its type, and returns the answers that are valid
    /// and still current. A late, failed or malformed answer is dropped
    /// without an error toward the user; `isCurrent` reports whether the
    /// document is still the version the call was made for.
    func query(
        type: String, document: PluginEditorProviderDocument, context: PluginWorkspaceContextReference,
        position: (line: Int, character: Int)?, triggerCharacter: String?,
        backends: any PluginBackendRequesting, isCurrent: @escaping @MainActor () -> Bool
    ) async -> [PluginEditorProviderAnswer] {
        let registrations = self.registrations(
            context: context, filename: document.filename, language: document.language, type: type)
        guard !registrations.isEmpty else { return [] }
        var members: [String: ToolingJSONValue] = [
            "documentID": .string(document.documentID), "version": .integer(Int(clamping: document.version)),
        ]
        if let position {
            members["position"] = .object(["line": .integer(position.line), "character": .integer(position.character)])
        }
        if let triggerCharacter { members["triggerCharacter"] = .string(triggerCharacter) }
        let params: ToolingJSONValue = .object(members)
        var answers: [PluginEditorProviderAnswer] = []
        await withTaskGroup(of: PluginEditorProviderAnswer?.self) { group in
            for registration in registrations {
                // A character-triggered request only reaches registrations that asked for that character.
                guard let provider = registration.providers[type],
                      triggerCharacter.map({ provider.triggerCharacters.contains($0) }) ?? true else { continue }
                group.addTask { @MainActor [weak self] in
                    await self?.invoke(
                        registration, provider, type: type, params: params, context: context,
                        backends: backends, isCurrent: isCurrent)
                }
            }
            for await answer in group { if let answer { answers.append(answer) } }
        }
        return answers.sorted { ($0.registration.pluginID, $0.registration.id) < ($1.registration.pluginID, $1.registration.id) }
    }

    private func invoke(
        _ registration: PluginEditorProviderRegistration, _ provider: PluginEditorProviderRegistration.Provider,
        type: String, params: ToolingJSONValue, context: PluginWorkspaceContextReference,
        backends: any PluginBackendRequesting, isCurrent: @MainActor () -> Bool
    ) async -> PluginEditorProviderAnswer? {
        guard contains(registration, functionID: provider.functionID) else { return nil }
        do {
            let raw = try await backends.invokePluginFunction(
                provider.functionID, params: params, ofPlugin: registration.pluginID, context: context,
                timeout: provider.budget, progress: { _ in })
            try Task.checkCancellation()
            guard isCurrent(), contains(registration, functionID: provider.functionID) else { return nil }
            let decoded = try decoder.decodeEditorProviderResult(type: type, value: raw, legend: provider.legend)
            guard case .object(let object) = decoded, let result = object["result"] else { return nil }
            return PluginEditorProviderAnswer(registration: registration, provider: provider, result: result)
        } catch {
            if Task.isCancelled { return nil }
            if let plugin = LogSegment(registration.pluginID) {
                logSink?.emit(PluginsEditorProviderFailed(error: error, plugin: plugin))
            }
            return nil
        }
    }
}
