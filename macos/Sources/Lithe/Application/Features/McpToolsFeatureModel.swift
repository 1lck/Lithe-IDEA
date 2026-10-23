import Combine
import Foundation

/// One page owns all probes. Navigation cancels them and stale responses never
/// replace another connection's inventory or publish a success after failure.
@MainActor
final class McpToolsFeatureModel: ObservableObject {
    struct State {
        var isLoading = false
        var isReady = false
        var tools: [McpToolDescription] = []
        var policies: [McpAgent: McpToolPolicySnapshot] = [:]
        var error: String?
    }
    @Published private(set) var states: [String: State] = [:]
    var didChangePolicy: ((McpServerRow, McpToolPolicySnapshot) -> Void)?
    private let service: (any McpToolsManaging)?
    private var probes: [String: Task<Void, Never>] = [:]
    private var requests: [String: UUID] = [:]
    private var targets: [String: McpServerRow] = [:]

    init(service: (any McpToolsManaging)?) { self.service = service }

    func state(for row: McpServerRow) -> State { states[row.id] ?? State() }

    @discardableResult
    func detect(_ row: McpServerRow) -> Task<Void, Never>? {
        guard let service, !row.isProjectOnly else { return nil }
        cancelAll()
        targets[row.id] = row
        let request = UUID(); requests[row.id] = request
        var state = states[row.id] ?? State(); state.isLoading = true; state.isReady = false; state.error = nil
        states[row.id] = state
        probes[row.id] = Task { [weak self] in
            do {
                let result = try await service.probe(row.definition)
                guard let self, !Task.isCancelled, self.requests[row.id] == request else { return }
                self.states[row.id]?.tools = result.tools
                self.states[row.id]?.isReady = true
                self.loadPolicies(self.targets[row.id] ?? row)
            } catch {
                guard let self, !Task.isCancelled, self.requests[row.id] == request else { return }
                self.states[row.id]?.isReady = false
                // Probe errors cross a sanitized Core boundary; no raw server
                // response, URL, argument or header is put in the message.
                self.states[row.id]?.error = error.localizedDescription
            }
            guard let self, self.requests[row.id] == request else { return }
            self.states[row.id]?.isLoading = false
            self.probes[row.id] = nil
            self.requests[row.id] = nil
        }
        return probes[row.id]
    }

    func loadPolicies(_ row: McpServerRow) {
        guard let service, let state = states[row.id], state.isReady else { return }
        service.release(Array(state.policies.values))
        states[row.id]?.policies = [:]
        states[row.id]?.error = nil
        for agent in McpAgent.allCases where row.enabledGlobalAgents.contains(agent) {
            do {
                states[row.id]?.policies[agent] = try service.policy(for: target(row), agent: agent, tools: state.tools.map(\.name))
            } catch { states[row.id]?.error = error.localizedDescription }
        }
    }

    func setEnabled(_ enabled: Bool, tool: String, agent: McpAgent, row: McpServerRow) {
        guard let service, let snapshot = states[row.id]?.policies[agent] else { return }
        do {
            let next = try service.setEnabled(enabled, tool: tool, target: target(row), snapshot: snapshot)
            states[row.id]?.policies[agent] = next
            states[row.id]?.error = nil
            didChangePolicy?(row, next)
        } catch { states[row.id]?.error = error.localizedDescription }
    }

    func reconcile(_ rows: [McpServerRow]) {
        let ids = Set(rows.map(\.id))
        for id in Array(states.keys) where !ids.contains(id) {
            probes.removeValue(forKey: id)?.cancel(); requests[id] = nil
            if let state = states.removeValue(forKey: id) { service?.release(Array(state.policies.values)) }
            targets[id] = nil
        }
        for row in rows where states[row.id] != nil {
            let previous = targets.updateValue(row, forKey: row.id)
            // Registration changes leave connection identity and inventory intact.
            // Refresh local policy without connecting to the server a second time.
            if previous?.globalSources != row.globalSources { loadPolicies(row) }
        }
    }

    func cancelAll() {
        for task in probes.values { task.cancel() }
        probes.removeAll(); requests.removeAll()
        for id in Array(states.keys) { states[id]?.isLoading = false }
    }

    func leavePage() {
        cancelAll()
        for state in states.values { service?.release(Array(state.policies.values)) }
        states.removeAll()
        targets.removeAll()
    }

    func commandLine(_ draft: McpServerDraft) throws -> String {
        guard let service else { throw McpLibraryError.unavailable }
        return try service.commandLine(command: draft.command, args: draft.arguments)
    }

    func updateCommandLine(_ line: String, draft: inout McpServerDraft) throws {
        guard let service else { throw McpLibraryError.unavailable }
        let parsed = try service.parseCommandLine(line)
        draft.setCommand(parsed.command, arguments: parsed.args)
    }

    private func target(_ row: McpServerRow) -> McpToolTarget {
        McpToolTarget(definition: row.definition, files: row.globalSources.map(\.file))
    }
}
