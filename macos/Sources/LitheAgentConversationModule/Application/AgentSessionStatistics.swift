import Foundation

/// Token counters shown for a session, from exactly one accounting source.
public struct AgentSessionTokens: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Provider counters of every request observed by the Host proxy.
        case modelCalls
        /// The latest turn's optional counters reported by the Agent over ACP.
        /// Their scope is Agent-owned, so turns are never summed.
        case latestAgentTurn
    }

    public let source: Source
    /// Prompt tokens neither read from nor written to the provider cache.
    public let uncachedInputTokens: UInt64
    public let cacheReadTokens: UInt64
    public let cacheWriteTokens: UInt64
    public let outputTokens: UInt64
    public let reasoningTokens: UInt64?
    /// Observed calls without provider counters; when non-zero the sums are a
    /// lower bound rather than the session total.
    public var callsMissingUsage = 0

    public var promptTokens: UInt64 { uncachedInputTokens + cacheReadTokens + cacheWriteTokens }
    public var totalTokens: UInt64 { promptTokens + outputTokens }
    public var cacheHitRate: Double? {
        promptTokens > 0 ? Double(cacheReadTokens) / Double(promptTokens) : nil
    }
}

/// What the Agent panel's session status bar shows. Facts that need the
/// optional proxy are `nil` without it rather than estimated.
public struct AgentSessionStatistics: Equatable, Sendable {
    /// Locally submitted turns, including the running one.
    public let turnCount: Int
    public let toolCallCount: Int
    /// Completed turns' time with running tools or pending permissions.
    public let toolDuration: TimeInterval
    /// Proxy observations; `nil` when no provider request was observed.
    public let modelCalls: AgentModelCallTotals?
    public let tokens: AgentSessionTokens?

    public init(_ conversation: AgentConversation) {
        let turns = conversation.completedTurns
        let baseline = conversation.statisticsBaseline
        turnCount = (baseline?.turnCount ?? 0) + turns.count + (conversation.activeTurn == nil ? 0 : 1)
        toolCallCount = (baseline?.toolCallCount ?? 0) + turns.reduce(0) { $0 + $1.toolCallCount }
            + conversation.activeTurnToolCallCount
        toolDuration = (baseline?.toolDuration ?? 0) + turns.reduce(0) { $0 + $1.toolDuration }
        var calls = baseline?.modelCalls ?? AgentModelCallTotals()
        calls.add(conversation.modelCalls)
        let observed = calls.callCount > 0 ? calls : nil
        modelCalls = observed
        if let observed, observed.hasUsage {
            tokens = AgentSessionTokens(source: .modelCalls, uncachedInputTokens: observed.inputTokens,
                                        cacheReadTokens: observed.cacheReadTokens,
                                        cacheWriteTokens: observed.cacheWriteTokens,
                                        outputTokens: observed.outputTokens, reasoningTokens: observed.reasoningTokens,
                                        callsMissingUsage: observed.callCount - observed.callsWithUsage)
        } else {
            tokens = (turns.last(where: { $0.usage != nil })?.usage ?? baseline?.latestUsage).map(Self.agentTokens)
        }
    }

    /// ACP leaves the input accounting scope to the Agent. A total smaller than
    /// input + output + cache reads proves that cache reads are part of input.
    static func agentTokens(_ usage: AgentTurnUsage) -> AgentSessionTokens {
        let cacheRead = usage.cachedReadTokens ?? 0
        let cacheWrite = usage.cachedWriteTokens ?? 0
        let inputIncludesCache = cacheRead > 0 && usage.totalTokens < usage.inputTokens + usage.outputTokens + cacheRead
        return AgentSessionTokens(
            source: .latestAgentTurn,
            uncachedInputTokens: inputIncludesCache
                ? usage.inputTokens.subtractingClamped(cacheRead + cacheWrite)
                : usage.inputTokens,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            outputTokens: usage.outputTokens, reasoningTokens: usage.thoughtTokens)
    }
}

/// Persisted session totals: the baseline plus completed turns of this
/// connection. The running turn is saved once it finishes; calls already
/// observed during it are part of `modelCalls` like in the live statistics.
public struct AgentSessionStatisticsRecord: Codable, Equatable, Sendable {
    public var turnCount: Int
    public var toolCallCount: Int
    public var toolDuration: TimeInterval
    public var modelCalls: AgentModelCallTotals
    /// Agent-reported counters of the latest turn that carried them.
    public var latestUsage: AgentTurnUsage?
    /// Last Agent-reported occupancy, not accumulated request/billing tokens.
    public var contextUsage: AgentContextUsage?
    /// Confirmed model option IDs and values; a different selection invalidates the snapshot.
    public var contextModels: [String: String]?
    /// Orders records for the bounded store; not part of the statistics.
    public var updatedAt: Date

    public init(turnCount: Int = 0, toolCallCount: Int = 0, toolDuration: TimeInterval = 0,
                modelCalls: AgentModelCallTotals = AgentModelCallTotals(), latestUsage: AgentTurnUsage? = nil,
                contextUsage: AgentContextUsage? = nil, contextModels: [String: String]? = nil,
                updatedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.toolDuration = toolDuration
        self.modelCalls = modelCalls
        self.latestUsage = latestUsage
        self.contextUsage = contextUsage
        self.contextModels = contextModels
        self.updatedAt = updatedAt
    }

    /// Nothing to keep: no finished turn, observed call, or reported occupancy.
    var isEmpty: Bool { turnCount == 0 && modelCalls.callCount == 0 && contextUsage == nil }

    func hasSameTotals(as other: Self) -> Bool {
        var other = other
        other.updatedAt = updatedAt
        return self == other
    }
}

public extension AgentConversation {
    var sessionStatistics: AgentSessionStatistics { AgentSessionStatistics(self) }

    /// Totals to persist for this session, excluding the unfinished turn's timing.
    func statisticsRecord(at date: Date) -> AgentSessionStatisticsRecord {
        let baseline = statisticsBaseline ?? AgentSessionStatisticsRecord()
        var calls = baseline.modelCalls
        calls.add(modelCalls)
        return AgentSessionStatisticsRecord(
            turnCount: baseline.turnCount + completedTurns.count,
            toolCallCount: baseline.toolCallCount + completedTurns.reduce(0) { $0 + $1.toolCallCount },
            toolDuration: baseline.toolDuration + completedTurns.reduce(0) { $0 + $1.toolDuration },
            modelCalls: calls,
            latestUsage: completedTurns.last(where: { $0.usage != nil })?.usage ?? baseline.latestUsage,
            contextUsage: contextUsage,
            contextModels: contextUsage == nil ? nil : contextModelValues,
            updatedAt: date)
    }

    /// Only confirmed upstream identifiers can bind a saved occupancy report to a model.
    var contextModelValues: [String: String] {
        configOptions.filter { $0.category == "model" }.reduce(into: [:]) { $0[$1.id] = $1.currentValue }
    }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
