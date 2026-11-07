import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 独立扩展点与领域契约的边界见 .agents/notes/implemented/architecture/2026-10-31-plugin-capability-and-domain-boundaries.md

/// One action a plugin answered for a document, kept with the binding it came
/// from so a later click can be validated against that same binding.
struct PluginEditorActionItem: Equatable {
    let registration: PluginEditorActionRegistration
    let action: PluginEditorAction
}

/// The toolbar button a plugin-owned language maps onto its editor actions.
enum PluginEditorActionIntent: Equatable {
    case run
    case debug
}

/// The function one toolbar click calls among a document's plugin actions.
struct PluginEditorActionChoice: Equatable {
    let item: PluginEditorActionItem
    let invocation: PluginEditorAction.Invocation
    let alternativeID: String?
}

/// Maps the host's Run and Debug buttons onto a plugin's own editor actions.
///
/// The host does not know what an action does; it only picks by the plugin's
/// declared presentation token. Run takes the first `run`/`run-all` action in
/// document order and Debug takes that action's `debug` alternative (or an
/// action drawn with `debug` itself), so the toolbar reaches the same plugin
/// function a gutter click would. No match leaves the decision to the caller.
enum PluginEditorActionLaunchSelection {
    static let runIcons: Set<String> = ["run", "run-all"]
    static let debugIcon = "debug"

    static func choose(_ items: [PluginEditorActionItem], intent: PluginEditorActionIntent) -> PluginEditorActionChoice? {
        let ordered = items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.action.range.start, right = rhs.element.action.range.start
            if left.line != right.line { return left.line < right.line }
            if left.column != right.column { return left.column < right.column }
            return lhs.offset < rhs.offset
        }.map(\.element)
        switch intent {
        case .run:
            guard let item = ordered.first(where: { runIcons.contains($0.action.icon) }) else { return nil }
            return PluginEditorActionChoice(item: item, invocation: item.action.invoke, alternativeID: nil)
        case .debug:
            for item in ordered where runIcons.contains(item.action.icon) {
                if let alternative = item.action.alternatives.first(where: { $0.icon == debugIcon }) {
                    return PluginEditorActionChoice(item: item, invocation: alternative.invoke, alternativeID: alternative.id)
                }
            }
            guard let item = ordered.first(where: { $0.action.icon == debugIcon }) else { return nil }
            return PluginEditorActionChoice(item: item, invocation: item.action.invoke, alternativeID: nil)
        }
    }
}

/// Collects a document's plugin editor actions and invokes a chosen one, the
/// same way for the gutter and the toolbar: one collection budget across all
/// bindings, per-binding failures logged and skipped, every function checked
/// against the live registration before and after the backend answers.
@MainActor
struct PluginEditorActionCollector {
    let service: PluginEditorActionHostService
    let backends: any PluginBackendRequesting
    let workspace: PluginWorkspaceContextReference
    let logSink: (any LogSink)?

    /// At most this many actions are kept for one document; more empties the answer.
    static let maximumActions = 1000

    /// `path` is the document's workspace-relative path, nil outside the workspace.
    static func input(documentID: String, version: UInt64, path: String?, text: String) -> ToolingJSONValue {
        .object([
            "document": .object([
                "documentID": .string(documentID),
                "version": .integer(Int(clamping: version)),
                "path": path.map(ToolingJSONValue.string) ?? .null,
            ]),
            "text": .string(text),
        ])
    }

    static func workspaceRelativePath(of url: URL, root: URL?) -> String? {
        guard let root else { return nil }
        let prefix = root.standardizedFileURL.path + "/", path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Whether `document` can be collected on this host at all.
    static func admits(_ document: EditorDocument, service: PluginEditorActionHostService) -> Bool {
        document.text.utf8.count <= service.host.actionSourceBytes
    }

    func registrations(for document: EditorDocument) -> [PluginEditorActionRegistration] {
        service.registrations(context: workspace, filename: document.url.lastPathComponent)
    }

    /// Asks every binding in turn. Throws only `CancellationError`.
    func collect(
        documentID: String, version: UInt64, path: String?, text: String,
        registrations: [PluginEditorActionRegistration]
    ) async throws -> [PluginEditorActionItem] {
        let input = Self.input(documentID: documentID, version: version, path: path, text: text)
        var items: [PluginEditorActionItem] = []
        let clock = ContinuousClock(), started = clock.now
        for registration in registrations {
            do {
                try Task.checkCancellation()
                guard let remaining = PluginEditorActionCollectionBudget.remaining(after: started.duration(to: clock.now)) else { break }
                guard service.contains(registration) else { continue }
                let result = try await backends.invokePluginFunction(registration.functionID, params: input,
                    ofPlugin: registration.pluginID, context: workspace, timeout: remaining, progress: { _ in })
                try Task.checkCancellation()
                let actions = try service.decode(result, text: text)
                guard service.contains(registration),
                      actions.allSatisfy({ action in action.functionIDs.allSatisfy { service.contains(registration, functionID: $0) } })
                else { continue }
                items.append(contentsOf: actions.map { PluginEditorActionItem(registration: registration, action: $0) })
                guard items.count <= Self.maximumActions else { return [] }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let plugin = LogSegment(registration.pluginID) { logSink?.emit(PluginsEditorActionsFailed(error: error, plugin: plugin)) }
            }
        }
        return items
    }

    /// Whether every function `items` would call is still registered.
    func stillRegistered(_ items: [PluginEditorActionItem]) -> Bool {
        items.allSatisfy { item in item.action.functionIDs.allSatisfy { service.contains(item.registration, functionID: $0) } }
    }

    /// Calls the chosen function through the ordinary invocation lifecycle and
    /// returns the locations the plugin asks the host to reveal, if any.
    func invoke(
        _ choice: PluginEditorActionChoice, documentID: String, expectedVersion: UInt64
    ) async throws -> PluginEditorReveal? {
        var members: [String: ToolingJSONValue] = [
            "documentID": .string(documentID), "expectedVersion": .integer(Int(clamping: expectedVersion)),
            "actionID": .string(choice.item.action.id), "data": choice.invocation.params,
        ]
        if let alternativeID = choice.alternativeID { members["alternativeID"] = .string(alternativeID) }
        let result = try await backends.invokePluginFunction(choice.invocation.functionID, params: .object(members),
            ofPlugin: choice.item.registration.pluginID, context: choice.item.registration.context,
            timeout: .seconds(60), progress: { _ in })
        try Task.checkCancellation()
        return try service.decodeReveal(result)
    }
}
