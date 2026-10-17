import Foundation
import LitheTerminalModule

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// A terminal tab that is about to be ended.
struct TerminalExitCandidate: Equatable, Sendable {
    /// Identifies the project window that owns the tab.
    let ownerID: UUID
    let sessionID: UUID
    let title: String
    let projectName: String
    let workingDirectory: String
    /// Programs other than the idle shell; empty for an idle tab.
    let programs: [TerminalRunningProgram]

    var recordID: String { "terminal:\(sessionID.uuidString)" }
}

/// A command an Agent started that is still running.
struct AgentTaskCandidate: Equatable, Sendable {
    /// Lifecycle record ID; stable while the task's root process lives.
    let id: String
    let agentName: String
    let workspace: String
    let commandLine: String
    let workingDirectory: String?
    let startedAt: Date?
    /// The task and the processes it started.
    let processCount: Int
}

/// A daemon, container or detached process that this instance started.
struct BackgroundResourceCandidate: Equatable, Sendable {
    /// Lifecycle record ID.
    let id: String
    let name: String
    let detail: String
    let processIDs: [Int32]
    let listeningPorts: [Int]
    let startedAt: Date?
    let recognizerID: String?
    let recognizedPolicy: ProcessExitPolicy?
    let kind: ProcessRecordKind
}

enum TerminalExitAnswer: Sendable {
    case terminate
    case reveal
    case cancel
}

enum AgentTaskExitAnswer: Sendable {
    case terminate
    case keep
    case cancel
}

/// The background-resource dialog's result; `nil` from the presenter cancels.
struct BackgroundResourceAnswer: Equatable, Sendable {
    /// Resources to end; every other listed resource is kept.
    let terminate: Set<String>
    /// Remember the choice for resources that have a recognizer.
    let remember: Bool
}

/// Why a confirmation is shown; only quitting can be cancelled.
enum ProcessConfirmationPurpose: Sendable {
    case quit
    case disconnect
    /// Leftovers of an earlier Lithe that did not quit normally.
    case startupSweep
}

/// Shows the confirmations of the exit flow. Implemented by the platform.
@MainActor
protocol ProcessExitConfirmationPresenting: AnyObject {
    func confirmTerminalOnQuit(_ terminal: TerminalExitCandidate, position: Int, count: Int) async -> TerminalExitAnswer
    func confirmTerminalClose(_ terminal: TerminalExitCandidate) async -> Bool
    func confirmAgentTask(
        _ task: AgentTaskCandidate,
        position: Int,
        count: Int,
        purpose: ProcessConfirmationPurpose
    ) async -> AgentTaskExitAnswer
    func chooseBackgroundResources(
        _ resources: [BackgroundResourceCandidate],
        purpose: ProcessConfirmationPurpose
    ) async -> BackgroundResourceAnswer?
}

extension AgentTaskCandidate {
    init(item: ProcessInventoryItem) {
        self.init(
            id: item.id,
            agentName: item.agentName ?? "Agent",
            workspace: item.workspace ?? "",
            commandLine: item.detail,
            workingDirectory: item.workingDirectory,
            startedAt: item.startDate,
            processCount: item.processes.count
        )
    }
}

extension BackgroundResourceCandidate {
    init(item: ProcessInventoryItem, listeningPorts: [Int] = []) {
        self.init(
            id: item.id,
            name: item.name,
            detail: item.detail,
            processIDs: item.processes.map { Int32(truncatingIfNeeded: $0.processId) },
            listeningPorts: listeningPorts,
            startedAt: item.startDate,
            recognizerID: nil,
            recognizedPolicy: nil,
            kind: item.kind
        )
    }
}

/// What the user approved for one quit, by record ID.
struct ProcessExitApproval: Equatable, Sendable {
    var terminateAgentTasks: [String] = []
    var keepAgentTasks: [String] = []
    var terminateResources: [String] = []
    var keepResources: [String] = []
    var gracefulStopMilliseconds: UInt64 = 5_000
}

enum ProcessExitOutcome: Equatable, Sendable {
    case proceed(ProcessExitApproval)
    /// The user cancelled; nothing was stopped.
    case cancelled
    /// The user wants to handle this terminal first; quitting is cancelled.
    case revealTerminal(TerminalExitCandidate)
}

/// Runs the confirmations of quitting, closing a terminal tab, closing an
/// Agent connection and the startup sweep.
///
/// Rust Core decides which records need a question (`processLifecycle.resolve`)
/// and turns the answers into what ends and what is kept, including remembered
/// choices (`processLifecycle.settle`). This type only orders the questions:
/// busy terminals one by one, Agent tasks one by one, then the background list.
/// Nothing is stopped here, and a cancel at any step discards the earlier answers.
@MainActor
final class ProcessExitCoordinator {
    private let core: any ProcessLifecycleClassifying
    private weak var presenter: (any ProcessExitConfirmationPresenting)?
    private let diagnostics: (String) -> Void

    init(
        core: any ProcessLifecycleClassifying,
        presenter: any ProcessExitConfirmationPresenting,
        diagnostics: @escaping (String) -> Void = { _ in }
    ) {
        self.core = core
        self.presenter = presenter
        self.diagnostics = diagnostics
    }

    func confirmQuit(
        settings: ProcessTerminationSettings,
        terminals: [TerminalExitCandidate],
        agentTasks: [AgentTaskCandidate],
        resources: [BackgroundResourceCandidate]
    ) async -> (outcome: ProcessExitOutcome, settings: ProcessTerminationSettings) {
        let records = terminals.map(Self.record) + agentTasks.map(Self.record) + resources.map(Self.record)
        let plan = resolve(.quit, settings: settings, records: records)
        var answers: [String: ProcessLifecycleAnswer] = [:]

        let busyTerminals = terminals.filter { plan.action(for: $0.recordID) == .confirm }
        for (index, terminal) in busyTerminals.enumerated() {
            switch await presenter?.confirmTerminalOnQuit(terminal, position: index + 1, count: busyTerminals.count) ?? .cancel {
            case .terminate: answers[terminal.recordID] = .terminate
            case .reveal: return (.revealTerminal(terminal), settings)
            case .cancel: return (.cancelled, settings)
            }
        }

        let confirmTasks = agentTasks.filter { plan.action(for: $0.id) == .confirm }
        for (index, task) in confirmTasks.enumerated() {
            switch await presenter?.confirmAgentTask(
                task, position: index + 1, count: confirmTasks.count, purpose: .quit
            ) ?? .cancel {
            case .terminate: answers[task.id] = .terminate
            case .keep: answers[task.id] = .keep
            case .cancel: return (.cancelled, settings)
            }
        }

        var remember = false
        let asked = resources.filter { plan.action(for: $0.id) == .ask }
        if !asked.isEmpty {
            guard let answer = await presenter?.chooseBackgroundResources(asked, purpose: .quit) else {
                return (.cancelled, settings)
            }
            for resource in asked {
                answers[resource.id] = answer.terminate.contains(resource.id) ? .terminate : .keep
            }
            remember = answer.remember
        }

        let recognizers = Dictionary(uniqueKeysWithValues: resources.compactMap { resource in
            resource.recognizerID.map { (resource.id, $0) }
        })
        // Without a settlement Lithe cannot tell what to keep; quitting anyway
        // could end something the user just chose to keep.
        guard let settlement = settle(plan, settings: settings, answers: answers, remember: remember, recognizers: recognizers) else {
            return (.cancelled, settings)
        }
        let taskIDs = Set(agentTasks.map(\.id))
        let resourceIDs = Set(resources.map(\.id))
        let approval = ProcessExitApproval(
            terminateAgentTasks: settlement.terminate.filter(taskIDs.contains),
            keepAgentTasks: settlement.keep.filter(taskIDs.contains),
            terminateResources: settlement.terminate.filter(resourceIDs.contains),
            keepResources: settlement.keep.filter(resourceIDs.contains),
            gracefulStopMilliseconds: plan.gracefulStopMilliseconds
        )
        return (.proceed(approval), settlement.settings)
    }

    /// Whether a terminal tab may be closed. An idle tab never asks.
    func confirmTerminalClose(
        settings: ProcessTerminationSettings,
        terminal: TerminalExitCandidate
    ) async -> Bool {
        let plan = resolve(.closeTerminalTab, settings: settings, records: [Self.record(terminal)])
        guard plan.action(for: terminal.recordID) == .confirm else { return true }
        return await presenter?.confirmTerminalClose(terminal) ?? false
    }

    /// Decides the tasks of an Agent connection that is closed while Lithe
    /// keeps running. Returns the IDs to keep; all others are ended.
    func confirmAgentDisconnect(
        settings: ProcessTerminationSettings,
        tasks: [AgentTaskCandidate]
    ) async -> Set<String> {
        let plan = resolve(.agentDisconnect, settings: settings, records: tasks.map(Self.record))
        var answers: [String: ProcessLifecycleAnswer] = [:]
        let confirm = tasks.filter { plan.action(for: $0.id) == .confirm }
        for (index, task) in confirm.enumerated() {
            // The connection is already closing, so there is nothing to cancel.
            let answer = await presenter?.confirmAgentTask(
                task, position: index + 1, count: confirm.count, purpose: .disconnect
            ) ?? .keep
            answers[task.id] = answer == .terminate ? .terminate : .keep
        }
        guard let settlement = settle(plan, settings: settings, answers: answers) else {
            return Set(tasks.map(\.id))
        }
        return Set(settlement.keep)
    }

    /// Decides what an earlier instance left running, from the plan Rust Core
    /// made for its inventory. Returns the item IDs to end; a dismissed
    /// question keeps everything.
    func confirmStartupSweep(
        settings: ProcessTerminationSettings,
        items: [ProcessInventoryItem],
        plan: ProcessLifecyclePlan
    ) async -> Set<String> {
        var answers: [String: ProcessLifecycleAnswer] = [:]
        let confirmTasks = items.filter { plan.action(for: $0.id) == .confirm }.map(AgentTaskCandidate.init)
        for (index, task) in confirmTasks.enumerated() {
            let answer = await presenter?.confirmAgentTask(
                task, position: index + 1, count: confirmTasks.count, purpose: .startupSweep
            ) ?? .keep
            answers[task.id] = answer == .terminate ? .terminate : .keep
        }
        let asked = items.filter { plan.action(for: $0.id) == .ask }.map { BackgroundResourceCandidate(item: $0) }
        if !asked.isEmpty, let answer = await presenter?.chooseBackgroundResources(asked, purpose: .startupSweep) {
            for resource in asked {
                answers[resource.id] = answer.terminate.contains(resource.id) ? .terminate : .keep
            }
        }
        return Set(settle(plan, settings: settings, answers: answers)?.terminate ?? [])
    }

    private func resolve(
        _ context: ProcessLifecycleContext,
        settings: ProcessTerminationSettings,
        records: [ProcessLifecycleRecord]
    ) -> ProcessLifecyclePlan {
        do {
            return try core.resolve(context: context, settings: settings, records: records)
        } catch {
            diagnostics("Process lifecycle policy failed; asking about every record: \(error)\n")
            // Without a decision, asking is the only choice that cannot end
            // something the user wanted to keep.
            return ProcessLifecyclePlan(
                gracefulStopMilliseconds: UInt64(settings.gracefulStopSeconds) * 1_000,
                decisions: records.map { record in
                    ProcessLifecycleDecision(
                        id: record.id,
                        kind: record.kind,
                        policy: .confirmEach,
                        action: record.kind == .terminal && record.idle ? .terminate
                            : record.kind == .terminal || record.kind == .agentTask ? .confirm : .ask,
                        reason: "policyUnavailable"
                    )
                }
            )
        }
    }

    private func settle(
        _ plan: ProcessLifecyclePlan,
        settings: ProcessTerminationSettings,
        answers: [String: ProcessLifecycleAnswer],
        remember: Bool = false,
        recognizers: [String: String] = [:]
    ) -> ProcessSettlement? {
        do {
            return try core.settle(ProcessSettlementRequest(
                settings: settings,
                decisions: plan.decisions.map {
                    ProcessSettleDecision(id: $0.id, action: $0.action, recognizerId: recognizers[$0.id])
                },
                answers: answers,
                remember: remember
            ))
        } catch {
            diagnostics("Process lifecycle settlement failed: \(error)\n")
            return nil
        }
    }

    private static func record(_ terminal: TerminalExitCandidate) -> ProcessLifecycleRecord {
        ProcessLifecycleRecord(id: terminal.recordID, kind: .terminal, ownership: .launched, idle: terminal.programs.isEmpty)
    }

    private static func record(_ task: AgentTaskCandidate) -> ProcessLifecycleRecord {
        ProcessLifecycleRecord(id: task.id, kind: .agentTask, ownership: .scopeToken)
    }

    private static func record(_ resource: BackgroundResourceCandidate) -> ProcessLifecycleRecord {
        ProcessLifecycleRecord(
            id: resource.id,
            kind: resource.kind,
            ownership: .scopeToken,
            recognizerId: resource.recognizerID,
            recognizedPolicy: resource.recognizedPolicy,
            detached: true
        )
    }
}
