import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md
// Field names and values are the `processLifecycle.resolve` contract in
// shared/contracts/rust-core-api.md; fixtures: shared/fixtures/process-lifecycle/.

enum ProcessLifecycleContext: String, Codable, Sendable {
    case quit
    case closeTerminalTab
    case agentDisconnect
    case crashRecovery
    case startupSweep
    case finalSweep
}

enum ProcessRecordKind: String, Codable, Sendable {
    case run
    case terminal
    case agentTask
    case languageServer
    case debugAdapter
    case pluginTool
    case sidecar
    case daemon
    case container
    case oneShot
}

enum ProcessExitPolicy: String, Codable, Sendable {
    case terminate
    case confirmEach
    case askOnExit
    case external
}

enum ProcessOwnershipProof: String, Codable, Sendable {
    case launched
    case scopeToken
    case instanceLabel
    case unproven
}

enum ProcessLifecycleAction: String, Codable, Sendable {
    case terminate
    case confirm
    case ask
    case retain
    case `defer`
    case ignore
}

enum TerminalQuitPolicy: String, Codable, CaseIterable, Sendable {
    case confirmEach
    case terminate
}

enum AgentTaskTerminationPolicy: String, Codable, CaseIterable, Sendable {
    case confirmEach
    case keep
    case terminate
}

enum BackgroundResourcePolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case terminate
    case keep
}

enum StartupSweepPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case terminate
}

enum RememberedProcessChoice: String, Codable, Sendable {
    case terminate
    case keep
}

/// The user's choices on the Process Termination Policy settings page.
struct ProcessTerminationSettings: Codable, Equatable, Sendable {
    static let gracefulStopSecondsRange = 1...60

    var terminalOnQuit: TerminalQuitPolicy = .confirmEach
    var confirmTerminalTabClose = true
    var agentTasks: AgentTaskTerminationPolicy = .confirmEach
    var backgroundResources: BackgroundResourcePolicy = .ask
    /// Choices remembered from the background-resource dialog, by recognizer ID.
    var rememberedChoices: [String: RememberedProcessChoice] = [:]
    var startupSweep: StartupSweepPolicy = .ask
    var gracefulStopSeconds = 5

    init() {}

    init(from decoder: any Decoder) throws {
        // Settings written by a newer or older build keep every field it knows.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        terminalOnQuit = (try? container.decode(TerminalQuitPolicy.self, forKey: .terminalOnQuit)) ?? defaults.terminalOnQuit
        confirmTerminalTabClose = (try? container.decode(Bool.self, forKey: .confirmTerminalTabClose))
            ?? defaults.confirmTerminalTabClose
        agentTasks = (try? container.decode(AgentTaskTerminationPolicy.self, forKey: .agentTasks)) ?? defaults.agentTasks
        backgroundResources = (try? container.decode(BackgroundResourcePolicy.self, forKey: .backgroundResources))
            ?? defaults.backgroundResources
        rememberedChoices = (try? container.decode([String: RememberedProcessChoice].self, forKey: .rememberedChoices))
            ?? defaults.rememberedChoices
        startupSweep = (try? container.decode(StartupSweepPolicy.self, forKey: .startupSweep)) ?? defaults.startupSweep
        gracefulStopSeconds = (try? container.decode(Int.self, forKey: .gracefulStopSeconds))
            .map { min(max($0, Self.gracefulStopSecondsRange.lowerBound), Self.gracefulStopSecondsRange.upperBound) }
            ?? defaults.gracefulStopSeconds
    }
}

/// One process or resource the host collected for a lifecycle decision.
struct ProcessLifecycleRecord: Codable, Equatable, Sendable {
    let id: String
    let kind: ProcessRecordKind
    let ownership: ProcessOwnershipProof
    var declaredPolicy: ProcessExitPolicy?
    var recognizerId: String?
    var recognizedPolicy: ProcessExitPolicy?
    var detached = false
    var idle = false
    var retained = false
    var terminationApproved: Bool?

    init(
        id: String,
        kind: ProcessRecordKind,
        ownership: ProcessOwnershipProof,
        declaredPolicy: ProcessExitPolicy? = nil,
        recognizerId: String? = nil,
        recognizedPolicy: ProcessExitPolicy? = nil,
        detached: Bool = false,
        idle: Bool = false,
        retained: Bool = false,
        terminationApproved: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ownership = ownership
        self.declaredPolicy = declaredPolicy
        self.recognizerId = recognizerId
        self.recognizedPolicy = recognizedPolicy
        self.detached = detached
        self.idle = idle
        self.retained = retained
        self.terminationApproved = terminationApproved
    }
}

struct ProcessLifecycleDecision: Codable, Equatable, Sendable {
    let id: String
    let kind: ProcessRecordKind
    let policy: ProcessExitPolicy
    let action: ProcessLifecycleAction
    let reason: String
}

struct ProcessLifecyclePlan: Codable, Equatable, Sendable {
    let gracefulStopMilliseconds: UInt64
    let decisions: [ProcessLifecycleDecision]

    func action(for id: String) -> ProcessLifecycleAction? {
        decisions.first { $0.id == id }?.action
    }
}

/// Decides how every Lithe-owned process ends. Deterministic; owned by Rust Core.
protocol ProcessLifecycleDeciding: Sendable {
    func resolve(
        context: ProcessLifecycleContext,
        settings: ProcessTerminationSettings,
        records: [ProcessLifecycleRecord]
    ) throws -> ProcessLifecyclePlan
}

// MARK: - Inventory (`processLifecycle.inventory`)

/// A process as identified across PID reuse; start time in microseconds since 1970.
struct ProcessInventoryIdentity: Codable, Hashable, Sendable {
    let processId: Int64
    let startTime: UInt64
}

/// One row of the host's process snapshot, as read from the platform.
struct ProcessSnapshotEntry: Encodable, Sendable {
    let processId: Int64
    let startTime: UInt64
    let parentProcessId: Int64
    let sessionId: Int64
    let hasControllingTerminal: Bool
    let name: String
    let executablePath: String
    let arguments: [String]
    let processScope: String?
    let agentScope: String?
    let workingDirectory: String?
}

/// An open Agent connection; `taskBaseline` is when its first prompt was sent.
struct AgentConnectionSnapshot: Encodable, Sendable {
    let scope: String
    let agentName: String
    let workspace: String
    let taskBaseline: UInt64?
}

enum ProcessInventoryMode: String, Codable, Sendable {
    /// The running instance, which knows its Agent connections.
    case live
    /// An instance that is gone.
    case leftover
}

enum ProcessInventoryCategory: String, Codable, Sendable {
    case agentTask
    case agentInfrastructure
    case backgroundService
    case terminal
    case other
}

struct ProcessInventoryRequest: Encodable, Sendable {
    let scope: String
    let mode: ProcessInventoryMode
    let applicationSessionId: Int64
    var excludedProcessIds: [Int64] = []
    var retained: [ProcessInventoryIdentity] = []
    var agentScopes: [String]?
    var approvedTermination: [ProcessInventoryIdentity] = []
    var agentConnections: [AgentConnectionSnapshot] = []
    let processes: [ProcessSnapshotEntry]
    /// When set, the response carries the plan for the items.
    var context: ProcessLifecycleContext?
    var settings = ProcessTerminationSettings()
}

/// One classified group of processes. `id` is also its lifecycle record ID.
struct ProcessInventoryItem: Decodable, Equatable, Sendable {
    let id: String
    let category: ProcessInventoryCategory
    let kind: ProcessRecordKind
    let detached: Bool
    let name: String
    let detail: String
    let rootProcessId: Int64
    let startedAt: UInt64
    let agentName: String?
    let workspace: String?
    let workingDirectory: String?
    let processes: [ProcessInventoryIdentity]

    var startDate: Date { Date(timeIntervalSince1970: Double(startedAt) / 1_000_000) }
}

struct ProcessInventory: Decodable, Sendable {
    let items: [ProcessInventoryItem]
    let plan: ProcessLifecyclePlan?
}

// MARK: - Settlement (`processLifecycle.settle`)

enum ProcessLifecycleAnswer: String, Codable, Sendable {
    case terminate
    case keep
}

struct ProcessSettleDecision: Encodable, Sendable {
    let id: String
    let action: ProcessLifecycleAction
    var recognizerId: String?
}

struct ProcessSettlementRequest: Encodable, Sendable {
    let settings: ProcessTerminationSettings
    let decisions: [ProcessSettleDecision]
    let answers: [String: ProcessLifecycleAnswer]
    let remember: Bool
}

/// What to end and keep after the user answered, plus remembered choices.
struct ProcessSettlement: Decodable, Equatable, Sendable {
    let terminate: [String]
    let keep: [String]
    let settings: ProcessTerminationSettings
}

/// Classifies processes and settles answers. Deterministic; owned by Rust Core.
protocol ProcessLifecycleClassifying: ProcessLifecycleDeciding {
    func inventory(_ request: ProcessInventoryRequest) throws -> ProcessInventory
    func settle(_ request: ProcessSettlementRequest) throws -> ProcessSettlement
}
