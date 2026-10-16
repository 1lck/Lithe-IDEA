import Darwin
import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// One command an Agent started, with the processes it started in turn.
struct MacAgentTask: Sendable {
    let candidate: AgentTaskCandidate
    let identities: [MacProcessIdentity]
}

/// Tracks the Agent connections of this instance and finds the tasks they run.
///
/// Every Agent process tree carries its own `LITHE_AGENT_SCOPE`, set by the
/// Agent host, so a task stays attributable after it calls `setsid` or is
/// re-parented. Processes that already ran when the first prompt was sent are
/// the Agent itself, its adapter and its MCP servers; later ones are tasks.
@MainActor
final class MacAgentProcessRegistry {
    static let application = MacAgentProcessRegistry()

    private struct Connection {
        let agentName: String
        let workspace: String
        var taskBaseline: UInt64?
        let preserve: @MainActor ([pid_t]) -> Void
    }

    private var connections: [String: Connection] = [:]
    /// Task IDs the quit confirmation kept; set only while quitting.
    private var quitKeptTaskIDs: Set<String>?
    /// Asks whether to keep the tasks of a connection closed while Lithe keeps
    /// running. Returns the task IDs to keep. Without it, tasks are kept.
    var confirmDisconnect: (@MainActor ([AgentTaskCandidate]) async -> Set<String>)?

    func register(
        scope: String,
        agentName: String,
        workspace: String,
        preserve: @escaping @MainActor ([pid_t]) -> Void
    ) {
        connections[scope] = Connection(agentName: agentName, workspace: workspace, preserve: preserve)
    }

    /// Marks the start of the first turn; called before the prompt is sent.
    func noteFirstPrompt(scope: String) {
        guard connections[scope]?.taskBaseline == nil else { return }
        connections[scope]?.taskBaseline = Self.now()
    }

    /// Running tasks of every open connection.
    func tasks(snapshot: [MacProcessInfo] = MacProcessTable.snapshot()) -> [MacAgentTask] {
        guard let instance = MacProcessInstance.current, !connections.isEmpty else { return [] }
        return tasks(instance: instance, connections: connections, snapshot: snapshot)
    }

    /// Applies the quit confirmation's answers to the connections that the
    /// application shutdown is about to close.
    func prepareForQuit(keeping taskIDs: Set<String>) {
        quitKeptTaskIDs = taskIDs
    }

    func cancelQuit() {
        quitKeptTaskIDs = nil
    }

    /// Ends the tasks the user did not keep and tells the host which processes
    /// to leave alone. Call before closing the connection.
    func prepareClose(scope: String) async {
        guard let connection = connections.removeValue(forKey: scope),
              let instance = MacProcessInstance.current else { return }
        let tasks = tasks(instance: instance, connections: [scope: connection], snapshot: MacProcessTable.snapshot())
        guard !tasks.isEmpty else { return }
        let keptIDs: Set<String>
        if let quitKeptTaskIDs {
            keptIDs = quitKeptTaskIDs
        } else if let confirmDisconnect {
            keptIDs = await confirmDisconnect(tasks.map(\.candidate))
        } else {
            keptIDs = Set(tasks.map(\.candidate.id))
        }
        let kept = tasks.filter { keptIDs.contains($0.candidate.id) }.flatMap(\.identities)
        let ended = tasks.filter { !keptIDs.contains($0.candidate.id) }.flatMap(\.identities)
        if !kept.isEmpty {
            // Before closing: once preserved, the host ends only the Agent process.
            connection.preserve(kept.map(\.processID))
            instance.retain(kept)
        }
        let gracePeriod = TimeInterval(MacProcessSupervisor.storedSettings().gracefulStopSeconds)
        await Task.detached { _ = MacProcessScopeScanner.terminate(ended, gracePeriod: gracePeriod) }.value
    }

    /// Grouping into tasks is decided by Rust Core (`processLifecycle.inventory`);
    /// only the connections' baselines are known here.
    private func tasks(
        instance: MacProcessInstance,
        connections: [String: Connection],
        snapshot: [MacProcessInfo]
    ) -> [MacAgentTask] {
        let snapshots = connections.keys.sorted().map { scope in
            let connection = connections[scope]!
            return AgentConnectionSnapshot(
                scope: scope,
                agentName: connection.agentName,
                workspace: connection.workspace,
                taskBaseline: connection.taskBaseline
            )
        }
        let inventory: ProcessInventory
        do {
            inventory = try MacProcessInventoryReader().live(instance: instance, agentConnections: snapshots, snapshot: snapshot)
        } catch {
            return []
        }
        return inventory.items
            .filter { $0.category == .agentTask && $0.agentName != nil }
            .map { item in
                MacAgentTask(
                    candidate: AgentTaskCandidate(item: item),
                    identities: item.processes.map(MacProcessIdentity.init)
                )
            }
    }

    private static func now() -> UInt64 {
        var time = timeval()
        gettimeofday(&time, nil)
        return UInt64(time.tv_sec) * 1_000_000 + UInt64(time.tv_usec)
    }
}
