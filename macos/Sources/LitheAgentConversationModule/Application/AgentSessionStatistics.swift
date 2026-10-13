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
        turnCount = turns.count + (conversation.activeTurn == nil ? 0 : 1)
        toolCallCount = turns.reduce(0) { $0 + $1.toolCallCount } + conversation.activeTurnToolCallCount
        toolDuration = turns.reduce(0) { $0 + $1.toolDuration }
        let observed = conversation.modelCalls.callCount > 0 ? conversation.modelCalls : nil
        modelCalls = observed
        if let observed, observed.hasUsage {
            tokens = AgentSessionTokens(source: .modelCalls, uncachedInputTokens: observed.inputTokens,
                                        cacheReadTokens: observed.cacheReadTokens,
                                        cacheWriteTokens: observed.cacheWriteTokens,
                                        outputTokens: observed.outputTokens, reasoningTokens: observed.reasoningTokens,
                                        callsMissingUsage: observed.callCount - observed.callsWithUsage)
        } else {
            tokens = turns.last(where: { $0.usage != nil })?.usage.map(Self.agentTokens)
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

public extension AgentConversation {
    var sessionStatistics: AgentSessionStatistics { AgentSessionStatistics(self) }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
