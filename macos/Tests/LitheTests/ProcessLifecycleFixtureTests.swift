import Foundation
import Testing
import LitheTerminalModule
@testable import Lithe

/// Replays the shared process-lifecycle fixtures through the real Rust Core and
/// decodes the results with the Swift contract types, so a field renamed on
/// either side fails here instead of at quit time.
struct ProcessLifecycleFixtureTests {
    @Test func inventoryFixturesDecodeIntoSwiftTypes() throws {
        let core = RustCoreBridge()
        for testCase in try cases("inventory-v1.json") {
            let result: ProcessInventory = try core.executeResult(
                command: "processLifecycle.inventory",
                payload: testCase.request
            ).get()
            let expected = try testCase.expected.decode(ProcessInventory.self)
            #expect(result.items == expected.items, "\(testCase.name)")
            #expect(result.plan == expected.plan, "\(testCase.name)")
        }
    }

    @Test func settleFixturesDecodeIntoSwiftTypes() throws {
        let core = RustCoreBridge()
        for testCase in try cases("settle-v1.json") {
            let result: ProcessSettlement = try core.executeResult(
                command: "processLifecycle.settle",
                payload: testCase.request
            ).get()
            #expect(result == (try testCase.expected.decode(ProcessSettlement.self)), "\(testCase.name)")
        }
    }

    @Test func swiftSettlementRequestMatchesRust() throws {
        let settlement = try RustProcessLifecycleDecider(core: RustCoreBridge()).settle(ProcessSettlementRequest(
            settings: ProcessTerminationSettings(),
            decisions: [
                ProcessSettleDecision(id: "idle", action: .terminate),
                ProcessSettleDecision(id: "daemon", action: .ask, recognizerId: "example.daemon"),
                ProcessSettleDecision(id: "outside", action: .ignore),
            ],
            answers: ["daemon": .keep],
            remember: true
        ))
        #expect(settlement.terminate == ["idle"])
        #expect(settlement.keep == ["daemon"])
        #expect(settlement.settings.rememberedChoices == ["example.daemon": .keep])
    }

    private struct FixtureCase {
        let name: String
        let request: FixtureJSON
        let expected: FixtureJSON
    }

    private func cases(_ file: String) throws -> [FixtureCase] {
        let url = repositoryRoot.appendingPathComponent("shared/fixtures/process-lifecycle/\(file)")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let cases = try #require(root?["cases"] as? [[String: Any]])
        return try cases.map { entry in
            FixtureCase(
                name: try #require(entry["name"] as? String),
                request: FixtureJSON(try #require(entry["request"])),
                expected: FixtureJSON(try #require(entry["expected"]))
            )
        }
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }
}

/// Passes a fixture's JSON through unchanged.
private struct FixtureJSON: Encodable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            try container.encode(number.boolValue)
        case let number as NSNumber:
            if CFNumberIsFloatType(number) {
                try container.encode(number.doubleValue)
            } else {
                try container.encode(number.int64Value)
            }
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(FixtureJSON.init))
        case let object as [String: Any]:
            try container.encode(object.mapValues(FixtureJSON.init))
        default:
            try container.encodeNil()
        }
    }
}

/// The order in which quitting asks, and how answers become an approval.
@MainActor
struct ProcessExitCoordinatorTests {
    @Test func quitAsksTerminalsThenTasksThenServicesAndSettlesInRust() async {
        let presenter = ScriptedPresenter(
            terminal: .terminate,
            agentTask: .keep,
            resources: BackgroundResourceAnswer(terminate: ["service:20:2"], remember: false)
        )
        let coordinator = ProcessExitCoordinator(core: RustProcessLifecycleDecider(core: RustCoreBridge()), presenter: presenter)
        let busy = terminal(programs: [TerminalRunningProgram(processID: 10, commandLine: "mvn spring-boot:run")])
        let idle = terminal(programs: [])

        let (outcome, _) = await coordinator.confirmQuit(
            settings: ProcessTerminationSettings(),
            terminals: [busy, idle],
            agentTasks: [task("agentTask:30:3")],
            resources: [resource("service:20:2"), resource("service:21:2")]
        )

        #expect(presenter.asked == ["terminal:\(busy.sessionID)", "agentTask:30:3", "resources:service:20:2,service:21:2"])
        guard case .proceed(let approval) = outcome else {
            Issue.record("Expected to proceed, got \(outcome)")
            return
        }
        #expect(approval.keepAgentTasks == ["agentTask:30:3"])
        #expect(approval.terminateAgentTasks.isEmpty)
        #expect(approval.terminateResources == ["service:20:2"])
        #expect(approval.keepResources == ["service:21:2"])
        #expect(approval.gracefulStopMilliseconds == 5_000)
    }

    @Test func cancellingAnAgentTaskStopsAskingAndKeepsEverything() async {
        let presenter = ScriptedPresenter(terminal: .terminate, agentTask: .cancel, resources: nil)
        let coordinator = ProcessExitCoordinator(core: RustProcessLifecycleDecider(core: RustCoreBridge()), presenter: presenter)

        let (outcome, _) = await coordinator.confirmQuit(
            settings: ProcessTerminationSettings(),
            terminals: [],
            agentTasks: [task("agentTask:30:3")],
            resources: [resource("service:20:2")]
        )

        #expect(outcome == .cancelled)
        #expect(presenter.asked == ["agentTask:30:3"])
    }

    @Test func startupSweepEndsOnlyAnsweredItemsFromTheRustPlan() async throws {
        let presenter = ScriptedPresenter(
            terminal: .cancel,
            agentTask: .keep,
            resources: BackgroundResourceAnswer(terminate: ["service:20:2"], remember: false)
        )
        let decider = RustProcessLifecycleDecider(core: RustCoreBridge())
        let coordinator = ProcessExitCoordinator(core: decider, presenter: presenter)
        let inventory = try decider.inventory(ProcessInventoryRequest(
            scope: "earlier",
            mode: .leftover,
            applicationSessionId: 1,
            processes: [
                entry(20, sessionID: 20, name: "redis-server"),
                entry(30, sessionID: 30, name: "migrate", agentScope: "agent-1"),
            ],
            context: .startupSweep
        ))
        let plan = try #require(inventory.plan)

        let terminate = await coordinator.confirmStartupSweep(
            settings: ProcessTerminationSettings(),
            items: inventory.items,
            plan: plan
        )

        #expect(presenter.asked == ["agentTask:30:2", "resources:service:20:2"])
        #expect(terminate == ["service:20:2"])
    }

    private func terminal(programs: [TerminalRunningProgram]) -> TerminalExitCandidate {
        TerminalExitCandidate(
            ownerID: UUID(),
            sessionID: UUID(),
            title: "zsh",
            projectName: "demo",
            workingDirectory: "/tmp/demo",
            programs: programs
        )
    }

    private func task(_ id: String) -> AgentTaskCandidate {
        AgentTaskCandidate(
            id: id,
            agentName: "Agent",
            workspace: "/tmp/demo",
            commandLine: "migrate",
            workingDirectory: nil,
            startedAt: nil,
            processCount: 1
        )
    }

    private func resource(_ id: String) -> BackgroundResourceCandidate {
        BackgroundResourceCandidate(
            id: id,
            name: id,
            detail: id,
            processIDs: [],
            listeningPorts: [],
            startedAt: nil,
            recognizerID: nil,
            recognizedPolicy: nil,
            kind: .daemon
        )
    }

    private func entry(_ processID: Int64, sessionID: Int64, name: String, agentScope: String? = nil) -> ProcessSnapshotEntry {
        ProcessSnapshotEntry(
            processId: processID,
            startTime: 2,
            parentProcessId: 1,
            sessionId: sessionID,
            hasControllingTerminal: false,
            name: name,
            executablePath: "/usr/bin/\(name)",
            arguments: [name],
            processScope: "earlier",
            agentScope: agentScope,
            workingDirectory: nil
        )
    }
}

/// Answers every question the same way and records what was asked.
@MainActor
private final class ScriptedPresenter: ProcessExitConfirmationPresenting {
    private let terminal: TerminalExitAnswer
    private let agentTask: AgentTaskExitAnswer
    private let resources: BackgroundResourceAnswer?
    private(set) var asked: [String] = []

    init(terminal: TerminalExitAnswer, agentTask: AgentTaskExitAnswer, resources: BackgroundResourceAnswer?) {
        self.terminal = terminal
        self.agentTask = agentTask
        self.resources = resources
    }

    func confirmTerminalOnQuit(_ terminal: TerminalExitCandidate, position: Int, count: Int) async -> TerminalExitAnswer {
        asked.append(terminal.recordID)
        return self.terminal
    }

    func confirmTerminalClose(_ terminal: TerminalExitCandidate) async -> Bool {
        asked.append(terminal.recordID)
        return true
    }

    func confirmAgentTask(
        _ task: AgentTaskCandidate,
        position: Int,
        count: Int,
        purpose: ProcessConfirmationPurpose
    ) async -> AgentTaskExitAnswer {
        asked.append(task.id)
        return agentTask
    }

    func chooseBackgroundResources(
        _ resources: [BackgroundResourceCandidate],
        purpose: ProcessConfirmationPurpose
    ) async -> BackgroundResourceAnswer? {
        asked.append("resources:" + resources.map(\.id).joined(separator: ","))
        return self.resources
    }
}
