import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 编辑器 Provider 与语言服务器的合并取舍见 .agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md

/// Bridges the web editor's language-feature requests to the plugin editor
/// providers registered on this window's workspace context. The web editor
/// only names a provider type and a position; function IDs, registrations and
/// code lens parameters stay behind opaque per-batch keys on this side, and
/// every answer is validated by Core before it reaches the page.
@MainActor
final class MonacoPluginEditorProviders {
    /// Provider types the page asks for. Definitions are answered through the
    /// host's own navigation (see `AppModel.pluginDefinitionQuery`).
    static let pageTypes: Set<String> = ["hover", "completion", "codeLens", "foldingRange", "semanticTokens", "documentLink"]
    private static let maximumRequests = 32
    private static let maximumExecutions = 16
    private static let maximumLenses = 1000
    private static let maximumLinks = 1000
    /// Link targets the host opens itself; any other scheme is dropped.
    private static let linkSchemes: Set<String> = ["http", "https", "file"]

    private struct LensItem {
        let registration: PluginEditorProviderRegistration
        let functionID: String
        let params: ToolingJSONValue
    }
    private struct LensList {
        let batch: String
        let version: UInt64
        let items: [String: LensItem]
    }
    private struct LinkList {
        let batch: String
        let version: UInt64
        let targets: [String: URL]
    }
    private var lensLists: [String: LensList] = [:]
    private var linkLists: [String: LinkList] = [:]
    private var requests: [UUID: (documentID: String, task: Task<Void, Never>)] = [:]
    private var executions: [UUID: (documentID: String, item: LensItem, task: Task<Void, Never>)] = [:]
    private var subscription: AnyCancellable?

    /// Cancels in-flight requests when a registration is withdrawn or added,
    /// then asks the page to ask again. Every list the page holds is stale.
    func observe(model: AppModel, refresh: @escaping @MainActor () -> Void) {
        guard subscription == nil, let service = model.services.pluginEditorProviders else { return }
        subscription = service.changes.receive(on: DispatchQueue.main).sink { [weak self, weak service] in
            guard let self, let service else { return }
            self.cancelRequests()
            self.lensLists.removeAll()
            self.linkLists.removeAll()
            for (id, execution) in self.executions
            where !service.contains(execution.item.registration, functionID: execution.item.functionID) {
                execution.task.cancel()
                self.executions[id] = nil
            }
            refresh()
        }
    }

    /// Forgets one document's lists; `closing` also cancels its executions.
    func cancel(documentID: String, closing: Bool) {
        lensLists[documentID] = nil
        linkLists[documentID] = nil
        for (id, request) in requests where request.documentID == documentID {
            request.task.cancel()
            requests[id] = nil
        }
        if closing {
            for (id, execution) in executions where execution.documentID == documentID {
                execution.task.cancel()
                executions[id] = nil
            }
        }
    }

    func cancelAll() {
        cancelRequests()
        executions.values.forEach { $0.task.cancel() }
        executions.removeAll()
        lensLists.removeAll()
        linkLists.removeAll()
    }

    private func cancelRequests() {
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
    }

    /// Answers one `pluginEditorProviders` page message. `isCurrent` reports
    /// whether the document is still the revision the page asked about. A
    /// request nothing applies to gets the type's empty answer, so the page
    /// falls back to the language server alone.
    func answer(
        body: [String: Any], document: EditorDocument, documentID: String, model: AppModel,
        isCurrent: @escaping @MainActor () -> Bool, reply: @escaping (Any?, String?) -> Void
    ) {
        guard let type = body["provider"] as? String, Self.pageTypes.contains(type),
              let language = body["language"] as? String else { reply(nil, "Invalid provider request"); return }
        guard isCurrent() else { reply(["cancelled": true], nil); return }
        var position: (line: Int, character: Int)?
        if type == "hover" || type == "completion" {
            guard let line = body["line"] as? Int, let character = body["character"] as? Int,
                  line >= 0, character >= 0 else { reply(nil, "Invalid provider position"); return }
            position = (line, character)
        }
        let version = document.contentVersion
        let item = PluginEditorProviderDocument(
            documentID: documentID, version: version, filename: document.url.lastPathComponent, language: language)
        guard let service = model.services.pluginEditorProviders, let backends = model.pluginWebBackends,
              let workspace = model.pluginWebWorkspaceContext,
              model.services.pluginWorkspaceContexts?.contexts.contains(where: { $0.reference == workspace && $0.authority == .local }) == true,
              document.text.utf8.count <= PluginEditorProviderHostService.snapshotLimitBytes,
              !service.registrations(context: workspace, filename: item.filename, language: language, type: type).isEmpty,
              requests.count < Self.maximumRequests else {
            reply(payload(type: type, answers: [], service: nil, documentID: documentID, version: version).foundationObject, nil)
            return
        }
        let requestID = UUID()
        let trigger = body["triggerCharacter"] as? String
        let task = Task { @MainActor [weak self, weak document] in
            let answers = await service.query(
                type: type, document: item, context: workspace, position: position, triggerCharacter: trigger,
                backends: backends,
                isCurrent: { [weak document] in isCurrent() && document?.contentVersion == version })
            defer { self?.requests[requestID] = nil }
            guard let self, let document, !Task.isCancelled, isCurrent(), document.contentVersion == version else {
                reply(["cancelled": true], nil); return
            }
            reply(self.payload(type: type, answers: answers, service: service, documentID: documentID, version: version).foundationObject, nil)
        }
        requests[requestID] = (documentID, task)
    }

    /// The page's view of the answers: Core's normalized shapes, merged for
    /// the type. Lens commands become opaque keys; nothing private to a
    /// plugin is handed to the page.
    private func payload(
        type: String, answers: [PluginEditorProviderAnswer], service: PluginEditorProviderHostService?,
        documentID: String, version: UInt64
    ) -> ToolingJSONValue {
        func members(_ answer: PluginEditorProviderAnswer, _ key: String) -> [ToolingJSONValue] {
            guard case .object(let result) = answer.result, case .array(let list)? = result[key] else { return [] }
            return list
        }
        switch type {
        case "hover":
            var range: ToolingJSONValue?
            for answer in answers where range == nil {
                if case .object(let result) = answer.result { range = result["range"] }
            }
            var value: [String: ToolingJSONValue] = ["contents": .array(answers.flatMap { members($0, "contents") })]
            value["range"] = range
            return .object(value)
        case "completion":
            let incomplete = answers.contains {
                if case .object(let result) = $0.result, case .bool(true)? = result["isIncomplete"] { true } else { false }
            }
            return .object(["isIncomplete": .bool(incomplete), "items": .array(answers.flatMap { members($0, "items") })])
        case "codeLens":
            var items: [String: LensItem] = [:]
            var lenses: [ToolingJSONValue] = []
            for answer in answers {
                for lens in members(answer, "lenses") {
                    guard case .object(let object) = lens, let range = object["range"],
                          case .object(let command)? = object["command"], case .string(let title)? = command["title"],
                          case .string(let functionID)? = command["command"], case .array(let arguments)? = command["arguments"],
                          let params = arguments.first,
                          service?.contains(answer.registration, functionID: functionID) == true,
                          items.count < Self.maximumLenses else { continue }
                    let key = UUID().uuidString
                    items[key] = LensItem(registration: answer.registration, functionID: functionID, params: params)
                    lenses.append(.object(["id": .string(key), "range": range, "title": .string(title)]))
                }
            }
            // Nothing to click: no list to remember.
            guard !items.isEmpty else { return .object(["batch": .string(""), "lenses": .array([])]) }
            let batch = UUID().uuidString
            lensLists[documentID] = LensList(batch: batch, version: version, items: items)
            return .object(["batch": .string(batch), "lenses": .array(lenses)])
        case "foldingRange":
            return .object(["ranges": .array(answers.flatMap { members($0, "ranges") })])
        case "semanticTokens":
            // Registrations may declare different legends, so each answer keeps its own.
            return .object(["responses": .array(answers.compactMap { answer in
                guard case .object(let result) = answer.result, let data = result["data"], let legend = answer.provider.legend else { return nil }
                return .object(["legend": legend, "data": data])
            })])
        default:
            var targets: [String: URL] = [:]
            var links: [ToolingJSONValue] = []
            for answer in answers {
                for link in members(answer, "links") {
                    guard case .object(let object) = link, let range = object["range"],
                          case .string(let target)? = object["target"], let url = URL(string: target),
                          let scheme = url.scheme?.lowercased(), Self.linkSchemes.contains(scheme),
                          targets.count < Self.maximumLinks else { continue }
                    let key = UUID().uuidString
                    targets[key] = url
                    var entry: [String: ToolingJSONValue] = ["id": .string(key), "range": range]
                    entry["tooltip"] = object["tooltip"]
                    links.append(.object(entry))
                }
            }
            // Nothing to click: no list to remember.
            guard !targets.isEmpty else { return .object(["batch": .string(""), "links": .array([])]) }
            let batch = UUID().uuidString
            linkLists[documentID] = LinkList(batch: batch, version: version, targets: targets)
            return .object(["batch": .string(batch), "links": .array(links)])
        }
    }

    /// Opens the target of a clicked document link. The page names only the
    /// opaque batch and link keys, so a plugin's target never comes from the page.
    func open(
        body: [String: Any], document: EditorDocument, documentID: String, model: AppModel,
        isCurrent: @escaping @MainActor () -> Bool, reply: @escaping (Any?, String?) -> Void
    ) {
        guard isCurrent(), let list = linkLists[documentID], list.batch == body["batch"] as? String,
              list.version == document.contentVersion, let key = body["link"] as? String,
              let url = list.targets[key] else { reply(["cancelled": true], nil); return }
        model.openPluginDocumentLink(url)
        reply(["ok": true], nil)
    }

    /// Runs the function of a clicked code lens. The page names only the
    /// opaque batch and lens keys.
    func run(
        body: [String: Any], document: EditorDocument, documentID: String, model: AppModel,
        isCurrent: @escaping @MainActor () -> Bool, reply: @escaping (Any?, String?) -> Void
    ) {
        guard isCurrent(), let list = lensLists[documentID], list.batch == body["batch"] as? String,
              list.version == document.contentVersion, let key = body["lens"] as? String, let item = list.items[key],
              let service = model.services.pluginEditorProviders,
              service.contains(item.registration, functionID: item.functionID),
              model.pluginWebWorkspaceContext == item.registration.context, let backends = model.pluginWebBackends,
              executions.count < Self.maximumExecutions else { reply(["cancelled": true], nil); return }
        model.editorDidFocus(document)
        let operation = UUID()
        let params: ToolingJSONValue = .object([
            "documentID": .string(documentID), "expectedVersion": .integer(Int(clamping: list.version)), "data": item.params,
        ])
        let task = Task { @MainActor [weak self, weak model] in
            defer { self?.executions[operation] = nil }
            do {
                _ = try await backends.invokePluginFunction(
                    item.functionID, params: params, ofPlugin: item.registration.pluginID,
                    context: item.registration.context, timeout: .seconds(60), progress: { _ in })
                try Task.checkCancellation()
                reply(["ok": true], nil)
            } catch {
                if Task.isCancelled { reply(["cancelled": true], nil); return }
                var reference: LogRecordReference?
                if let plugin = LogSegment(item.registration.pluginID) {
                    let event = PluginsEditorProviderFailed(error: error, plugin: plugin)
                    model?.services.logSink?.emit(event)
                    reference = event.reference
                }
                model?.showNotification(L10n.string("The plugin host request could not be completed."), logReference: reference)
                reply(["ok": false], nil)
            }
        }
        executions[operation] = (documentID, item, task)
    }
}
