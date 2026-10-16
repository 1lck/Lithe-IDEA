import Foundation
import Testing
@testable import Lithe

@MainActor
struct AgentProcessRetentionTests {
    @Test func quitCommitsEveryProjectsKeptProcessesBeforeConnectionsClose() {
        var protections: [[MacProcessIdentity]] = []
        var firstHost: [Int32] = []
        var secondHost: [Int32] = []
        var unkeptHost: [Int32] = []
        let registry = MacAgentProcessRegistry(
            retainProcesses: { protections.append($0) },
            agentScope: { $0.processID == 100 ? "first-scope" : "second-scope" }
        )
        registry.register(scope: "first-scope", agentName: "Agent", workspace: "/first", preserve: { firstHost += $0 })
        registry.register(scope: "second-scope", agentName: "Agent", workspace: "/second", preserve: { secondHost += $0 })
        registry.register(scope: "unkept-scope", agentName: "Agent", workspace: "/third", preserve: { unkeptHost += $0 })
        let first = task(id: "first", pid: 100, workspace: "/first")
        let second = task(id: "second", pid: 200, workspace: "/second")
        let ended = task(id: "ended", pid: 300, workspace: "/first")
        registry.prepareForQuit(keeping: ["first", "second"], tasks: [first, second, ended])
        #expect(protections.isEmpty)
        // This boundary precedes the first project's shutdown and the update
        // watchdog. Neither connection has started closing yet.
        registry.commitQuitRetention()
        #expect(Set(protections.flatMap { $0 }) == Set(first.identities + second.identities))
        #expect(firstHost == [100])
        #expect(secondHost == [200])
        #expect(unkeptHost.isEmpty)
    }

    @Test func cancelledQuitDoesNotRetainStagedTasks() {
        var protected: [MacProcessIdentity] = []
        let registry = MacAgentProcessRegistry(retainProcesses: { protected += $0 })
        registry.prepareForQuit(keeping: ["first"], tasks: [task(id: "first", pid: 100, workspace: "/first")])
        registry.cancelQuit()
        registry.commitQuitRetention()
        #expect(protected.isEmpty)
    }

    @Test func keepingOneTaskStillEndsInfrastructureAndUnkeptSibling() {
        let inventory = ProcessInventory(items: [
            item(id: "kept", category: .agentTask, pids: [100, 101]),
            item(id: "ended", category: .agentTask, pids: [200, 201]),
            item(id: "infrastructure", category: .agentInfrastructure, pids: [10, 11, 12]),
            item(id: "other-connection", category: .other, pids: [400]),
        ], plan: nil)
        let ended = MacAgentProcessRegistry.processesToEnd(in: inventory, keeping: ["kept"])
        #expect(Set(ended.map(\.processID)) == [10, 11, 12, 200, 201])
    }

    @Test func quitCleanupSkipsDeferredTasksButEndsApprovedSiblingAndInfrastructure() {
        let inventory = ProcessInventory(items: [
            item(id: "late-task", category: .agentTask, pids: [100]),
            item(id: "approved", category: .agentTask, pids: [200]),
            item(id: "infrastructure", category: .agentInfrastructure, pids: [10]),
        ], plan: ProcessLifecyclePlan(gracefulStopMilliseconds: 0, decisions: [
            ProcessLifecycleDecision(id: "late-task", kind: .agentTask, policy: .confirmEach,
                action: .defer, reason: "agentTaskRequiresStartupConfirmation"),
            ProcessLifecycleDecision(id: "approved", kind: .agentTask, policy: .confirmEach,
                action: .terminate, reason: "finalSweepApproved"),
            ProcessLifecycleDecision(id: "infrastructure", kind: .sidecar, policy: .terminate,
                action: .terminate, reason: "finalSweepApproved"),
        ]))
        let ended = MacAgentProcessRegistry.processesToEnd(in: inventory, keeping: [])
        #expect(Set(ended.map(\.processID)) == [10, 200])
    }

    @Test func terminalTerminationUsesConfiguredGracePeriod() {
        var settings = ProcessTerminationSettings()
        settings.gracefulStopSeconds = 1
        #expect(MacTerminalTransport.terminationGracePeriod(settings: settings) == .seconds(1))
        settings.gracefulStopSeconds = 60
        #expect(MacTerminalTransport.terminationGracePeriod(settings: settings) == .seconds(60))
    }

    private func task(id: String, pid: Int32, workspace: String) -> MacAgentTask {
        MacAgentTask(
            candidate: AgentTaskCandidate(id: id, agentName: "Agent", workspace: workspace,
                commandLine: "task", workingDirectory: workspace, startedAt: nil, processCount: 1),
            identities: [MacProcessIdentity(processID: pid, startTime: UInt64(pid))]
        )
    }

    private func item(id: String, category: ProcessInventoryCategory, pids: [Int64]) -> ProcessInventoryItem {
        ProcessInventoryItem(id: id, category: category, kind: .agentTask, detached: false,
            name: id, detail: id, rootProcessId: pids[0], startedAt: 1, agentName: "Agent",
            workspace: "/project", workingDirectory: nil,
            processes: pids.map { ProcessInventoryIdentity(processId: $0, startTime: UInt64($0)) })
    }
}
