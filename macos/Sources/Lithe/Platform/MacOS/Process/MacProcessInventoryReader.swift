import Darwin
import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Reads a process snapshot and lets Rust Core classify it.
///
/// Only the facts the platform alone can read are gathered here (PIDs,
/// sessions, terminals, inherited environment, working directories); grouping
/// and categories come from `processLifecycle.inventory`, the same rules the
/// Windows host uses.
struct MacProcessInventoryReader: Sendable {
    let core: any ProcessLifecycleClassifying
    private let scopedProcesses: @Sendable (String, Set<pid_t>, [MacProcessInfo]) -> [MacScopedProcess]

    init(
        core: any ProcessLifecycleClassifying = RustProcessLifecycleDecider(core: RustCoreBridge()),
        scopedProcesses: @escaping @Sendable (String, Set<pid_t>, [MacProcessInfo]) -> [MacScopedProcess] = {
            MacProcessScopeScanner.processes(in: $0, excluding: $1, snapshot: $2)
        }
    ) {
        self.core = core
        self.scopedProcesses = scopedProcesses
    }

    /// Items of the running instance.
    func live(
        instance: MacProcessInstance,
        agentConnections: [AgentConnectionSnapshot] = [],
        agentScopes: [String]? = nil,
        snapshot: [MacProcessInfo] = MacProcessTable.snapshot()
    ) throws -> ProcessInventory {
        try inventory(
            scope: instance.scope.id,
            mode: .live,
            applicationSessionID: instance.applicationSessionID,
            excluded: instance.excludedProcessIDs,
            retained: instance.retained,
            agentConnections: agentConnections,
            agentScopes: agentScopes,
            snapshot: snapshot
        )
    }

    func inventory(
        scope: String,
        mode: ProcessInventoryMode,
        applicationSessionID: pid_t? = nil,
        excluded: Set<pid_t>,
        retained: [MacProcessIdentity],
        agentConnections: [AgentConnectionSnapshot] = [],
        agentScopes: [String]? = nil,
        approvedTermination: [MacProcessIdentity] = [],
        context: ProcessLifecycleContext? = nil,
        settings: ProcessTerminationSettings = ProcessTerminationSettings(),
        snapshot: [MacProcessInfo] = MacProcessTable.snapshot()
    ) throws -> ProcessInventory {
        let processes = scopedProcesses(scope, excluded, snapshot)
        let originalSessionID = applicationSessionID.flatMap { $0 > 0 ? $0 : nil }
        var request = ProcessInventoryRequest(
            scope: scope,
            mode: mode,
            applicationSessionId: Int64(originalSessionID ?? 0),
            processes: processes.map(\.snapshotEntry)
        )
        request.excludedProcessIds = excluded.map(Int64.init).sorted()
        request.retained = MacProcessScopeScanner.retainedIdentities(retained, snapshot: snapshot)
            .sorted { ($0.processID, $0.startTime) < ($1.processID, $1.startTime) }
            .map(\.inventoryIdentity)
        request.agentConnections = agentConnections
        request.agentScopes = agentScopes
        request.approvedTermination = MacProcessScopeScanner.retainedIdentities(approvedTermination, snapshot: snapshot)
            .sorted { ($0.processID, $0.startTime) < ($1.processID, $1.startTime) }
            .map(\.inventoryIdentity)
        // A legacy record cannot authorize unattended cleanup from a guessed
        // session. Startup can still ask about its explicitly scoped leftovers.
        request.context = originalSessionID != nil || context == .startupSweep ? context : nil
        request.settings = settings
        return try core.inventory(request)
    }

    /// Background services of the running instance, with their listening ports.
    func backgroundServices(instance: MacProcessInstance) -> [(candidate: BackgroundResourceCandidate, item: ProcessInventoryItem)] {
        guard let inventory = try? live(instance: instance) else { return [] }
        return inventory.items
            .filter { $0.category == .backgroundService }
            .map { item in
                let ports = Set(item.processes.flatMap {
                    MacProcessTable.listeningTCPPorts(processID: pid_t(truncatingIfNeeded: $0.processId))
                })
                return (BackgroundResourceCandidate(item: item, listeningPorts: ports.sorted()), item)
            }
    }
}
