import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 声明式原生 UI 的状态与生命周期见 .agents/notes/implemented/feature/2026-10-21-declarative-native-plugin-ui.md

/// State and bounded calls for one native plugin window. The existing bridge
/// owns provider consent, scope checks, deadlines and process cancellation.
@MainActor
final class PluginNativeUIFeature: ObservableObject, PluginWebPageHandle {
    struct Row: Identifiable {
        let node: PluginNativeUI.Node
        let depth: Int
        var id: String { node.id }
    }
    struct State: Codable {
        var selection: String?
        var expanded: Set<String> = []
        var values: [String: PluginNativeUI.ControlValue]?
    }
    let declaration: PluginNativeUI
    @Published private(set) var nodes: [PluginNativeUI.Node]
    @Published private(set) var state: State
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    private let validateNodes: (PluginNativeUI, ToolingJSONValue) throws -> [PluginNativeUI.Node]
    private let request: (String, ToolingJSONValue) async throws -> ToolingJSONValue
    private let endRequests: () -> Void
    private let saveState: (State) -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var isClosed = false

    init(declaration: PluginNativeUI, state: State = .init(),
         validateNodes: @escaping (PluginNativeUI, ToolingJSONValue) throws -> [PluginNativeUI.Node],
         request: @escaping (String, ToolingJSONValue) async throws -> ToolingJSONValue,
         close: @escaping () -> Void = {}, saveState: @escaping (State) -> Void = { _ in }) {
        self.declaration = declaration
        self.nodes = declaration.nodes
        var restored = state
        restored.values = state.values?.filter { id, value in
            declaration.controls?.contains { $0.id == id && $0.accepts(value) } == true
        }
        self.state = restored
        self.validateNodes = validateNodes
        self.request = request
        self.endRequests = close
        self.saveState = saveState
    }

    var rows: [Row] {
        func flatten(_ nodes: [PluginNativeUI.Node], depth: Int) -> [Row] {
            nodes.flatMap { node in
                [Row(node: node, depth: depth)] + (state.expanded.contains(node.id)
                    ? flatten(node.children ?? [], depth: depth + 1) : [])
            }
        }
        return flatten(nodes, depth: 0)
    }

    func value(for control: PluginNativeUI.Control) -> PluginNativeUI.ControlValue {
        state.values?[control.id] ?? control.value
    }

    @discardableResult
    func setValue(_ value: PluginNativeUI.ControlValue, for control: PluginNativeUI.Control) -> Bool {
        guard !isClosed, !isBusy, control.enabled != false,
              declaration.controls?.contains(control) == true else { return false }
        guard control.accepts(value) else {
            error = L10n.string("The field value does not match its declaration or exceeds its size limit.")
            return false
        }
        guard value != self.value(for: control) else { return false }
        var updated = state
        updated.values = (updated.values ?? [:]).merging([control.id: value]) { _, new in new }
        guard let encoded = try? JSONEncoder().encode(updated), encoded.count <= PluginWebBridge.stateLimit else {
            error = L10n.string("The native panel state exceeds 64 KiB.")
            return false
        }
        state = updated
        error = nil
        saveState(state)
        return true
    }

    /// Text inputs commit on Return; selectors and checkboxes commit after a change.
    @discardableResult
    func commit(_ control: PluginNativeUI.Control) -> Task<Void, Never>? {
        guard control.enabled != false, declaration.controls?.contains(control) == true,
              let action = declaration.actions.first(where: { $0.id == control.onCommit }) else { return nil }
        return perform(action)
    }

    func canPerform(_ button: PluginNativeUI.Button) -> Bool {
        declaration.buttons?.contains(button) == true && button.enabled != false
            && declaration.actions.first(where: { $0.id == button.action }).map { canPerform($0) } == true
    }

    @discardableResult
    func perform(_ button: PluginNativeUI.Button) -> Task<Void, Never>? {
        guard canPerform(button), let action = declaration.actions.first(where: { $0.id == button.action }) else { return nil }
        return perform(action)
    }

    private var controlValues: ToolingJSONValue {
        .object(Dictionary(uniqueKeysWithValues: (declaration.controls ?? []).map { control in
            let value: ToolingJSONValue
            switch self.value(for: control) {
            case .text(let text): value = .string(text)
            case .checked(let checked): value = .bool(checked)
            case .number(let number): value = .number(number)
            }
            return (control.id, value)
        }))
    }

    func select(_ id: String) {
        guard !isClosed, rows.contains(where: { $0.id == id }) else { return }
        state.selection = id
        saveState(state)
    }

    func toggle(_ id: String) {
        guard !isClosed, rows.contains(where: { $0.id == id && !($0.node.children ?? []).isEmpty }) else { return }
        if !state.expanded.insert(id).inserted { state.expanded.remove(id) }
        if let selected = state.selection, !rows.contains(where: { $0.id == selected }) { state.selection = id }
        saveState(state)
    }

    func canPerform(_ action: PluginNativeUI.Action) -> Bool {
        !isClosed && !isBusy && declaration.actions.contains(action)
            && (!action.requiresSelection || rows.contains(where: { $0.id == state.selection }))
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? { start(nil) }
    @discardableResult
    func perform(_ action: PluginNativeUI.Action) -> Task<Void, Never>? {
        guard canPerform(action) else { return nil }
        return start(action.kind == .refresh ? nil : action)
    }

    /// Hiding/disabling a window cancels every request; late replies cannot publish.
    func close() {
        isClosed = true
        generation = UUID()
        task?.cancel()
        task = nil
        endRequests()
        isBusy = false
    }

    private func start(_ action: PluginNativeUI.Action?) -> Task<Void, Never>? {
        guard !isClosed, !isBusy, let source = declaration.source else { return nil }
        let token = UUID()
        generation = token
        isBusy = true
        error = nil
        message = nil
        let selection = state.selection
        let parameters: [String: ToolingJSONValue] = (declaration.controls ?? []).isEmpty ? [:] : ["values": controlValues]
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isBusy = false; self.task = nil } }
            do {
                let instances = try await self.request("build.instances", .object([:]))
                guard case .object(let instanceResult) = instances, case .array(let values)? = instanceResult["instances"] else {
                    throw PluginWebBridgeFailure.invalidRequest("The host returned invalid instances.")
                }
                let matches = values.compactMap { value -> String? in
                    guard case .object(let instance) = value,
                          instance["buildSystemID"] == .string(source.buildSystemID),
                          case .string(let id)? = instance["id"] else { return nil }
                    return id
                }
                // ponytail: one detected instance per native window in schema 1;
                // add an explicit instance selector before supporting multi-root actions.
                guard matches.count == 1, let instance = matches.first else {
                    throw PluginWebBridgeFailure.unavailable(L10n.string("This panel needs exactly one matching plugin instance in the workspace."))
                }
                try Task.checkCancellation()
                if let action, let function = action.function {
                    let reply = try await self.invoke(function, instance: instance,
                        params: .object(parameters.merging(["selectedID": selection.map(ToolingJSONValue.string) ?? .null]) { _, new in new }))
                    guard self.generation == token, !self.isClosed else { return }
                    if case .object(let body) = reply, case .string(let message)? = body["message"] {
                        self.message = String(message.prefix(1024))
                    }
                }
                try Task.checkCancellation()
                let result = try await self.invoke(source.function, instance: instance, params: .object(parameters))
                let nodes = try self.validateNodes(self.declaration, result)
                guard self.generation == token, !self.isClosed, !Task.isCancelled else { return }
                self.nodes = nodes
                var pending = nodes
                var ids = Set<String>()
                while let node = pending.popLast() {
                    ids.insert(node.id)
                    pending += node.children ?? []
                }
                self.state.expanded.formIntersection(ids)
                if let selection = self.state.selection, !ids.contains(selection) { self.state.selection = nil }
                self.saveState(self.state)
            } catch {
                guard self.generation == token, !self.isClosed, !Task.isCancelled else { return }
                self.error = (error as? PluginWebBridgeFailure)?.message
                    ?? (error as? DeclarativePluginRejection)?.message ?? error.localizedDescription
            }
        }
        return task
    }

    private func invoke(_ function: String, instance: String, params: ToolingJSONValue) async throws -> ToolingJSONValue {
        let reply = try await request("functions.invoke", .object([
            "instance": .string(instance), "function": .string(function), "params": params
        ]))
        try Task.checkCancellation()
        guard case .object(let body) = reply, let value = body["value"] else {
            throw PluginWebBridgeFailure.invalidRequest("The host returned an invalid function result.")
        }
        return value
    }

}
