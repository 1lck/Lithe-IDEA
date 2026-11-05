import Foundation

/// The Host's accounting of one provider request observed by its opt-in
/// loopback proxy: the `statistics` of a `modelCall` event. The Host decides
/// which requests are steps, failures, non-streaming answers, or the current
/// context; this product only adds contributions in event order.
/// Shape fixed by `shared/fixtures/agent/model-call-statistics-v1.json`.
public struct AgentModelCall: Decodable, Equatable, Sendable {
    /// Estimated split of the request prompt; see `scaledToUsage`.
    public struct Context: Codable, Equatable, Sendable {
        public let systemPromptTokens: UInt64
        public let toolTokens: UInt64
        public let mcpToolTokens: UInt64
        public let messageTokens: UInt64
        public let toolCount: Int
        public let mcpToolCount: Int
        /// Section sizes were scaled to the provider's prompt counters rather
        /// than approximated from byte length.
        public let scaledToUsage: Bool

        public var totalTokens: UInt64 { systemPromptTokens + toolTokens + mcpToolTokens + messageTokens }
    }

    public let requests: Int
    public let steps: Int
    public let failedSteps: Int
    public let nonStreamingSteps: Int
    public let durationMs: UInt64
    public let inputTokens: UInt64
    public let cacheReadTokens: UInt64
    public let cacheWriteTokens: UInt64
    public let outputTokens: UInt64
    public let reasoningTokens: UInt64?
    public let callsWithUsage: Int
    public let firstTokenMs: UInt64
    public let firstTokenCount: Int
    public let generationMs: UInt64
    public let generatedTokens: UInt64
    /// Present only when this request describes the conversation's current prompt.
    public let context: Context?

    static func parse(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Bounded aggregate of observed model calls for a turn or a session.
public struct AgentModelCallTotals: Codable, Equatable, Sendable {
    /// Counts main and auxiliary requests separately from conversation steps.
    /// Old documents omit it; their counters only provide a known lower bound.
    private var observedCallCount: Int?
    public var requestCount: Int { observedCallCount ?? max(callCount, callsWithUsage) }
    public var callsMissingUsage: Int { max(0, requestCount - callsWithUsage) }
    public private(set) var callCount = 0
    public private(set) var failedCount = 0
    public private(set) var nonStreamingCount = 0
    /// Sum of complete request durations, including time to first token.
    public private(set) var duration: TimeInterval = 0
    public private(set) var inputTokens: UInt64 = 0
    public private(set) var cacheReadTokens: UInt64 = 0
    public private(set) var cacheWriteTokens: UInt64 = 0
    public private(set) var outputTokens: UInt64 = 0
    public private(set) var reasoningTokens: UInt64?
    /// Calls whose provider response carried usage counters. Token sums cover
    /// only these; the rest (e.g. interrupted streams) are missing from them.
    public private(set) var callsWithUsage = 0
    public var hasUsage: Bool { callsWithUsage > 0 }
    /// Composition of the request the Host last reported as the current context.
    public private(set) var latestContext: AgentModelCall.Context?
    private var firstTokenTotal: TimeInterval = 0
    private var firstTokenCount = 0
    /// Streaming time after the first token, and the output produced in it.
    private var generationTime: TimeInterval = 0
    private var generatedTokens: UInt64 = 0

    public init() {}

    public var averageFirstToken: TimeInterval? {
        firstTokenCount > 0 ? firstTokenTotal / Double(firstTokenCount) : nil
    }

    /// Output rate while streaming, excluding the wait for the first token.
    public var outputTokensPerSecond: Double? {
        generationTime > 0 && generatedTokens > 0 ? Double(generatedTokens) / generationTime : nil
    }

    /// Adds a later period's totals, e.g. this connection's calls onto the
    /// persisted history of the session. A later composition replaces an earlier one.
    mutating func add(_ later: AgentModelCallTotals) {
        observedCallCount = requestCount + later.requestCount
        callCount += later.callCount
        failedCount += later.failedCount
        nonStreamingCount += later.nonStreamingCount
        duration += later.duration
        inputTokens += later.inputTokens
        cacheReadTokens += later.cacheReadTokens
        cacheWriteTokens += later.cacheWriteTokens
        outputTokens += later.outputTokens
        if let reasoning = later.reasoningTokens { reasoningTokens = (reasoningTokens ?? 0) + reasoning }
        callsWithUsage += later.callsWithUsage
        if let context = later.latestContext { latestContext = context }
        firstTokenTotal += later.firstTokenTotal
        firstTokenCount += later.firstTokenCount
        generationTime += later.generationTime
        generatedTokens += later.generatedTokens
    }

    /// Adds one Host contribution. Every rule about what counts lives in the Host.
    mutating func record(_ call: AgentModelCall) {
        observedCallCount = requestCount + call.requests
        callCount += call.steps
        failedCount += call.failedSteps
        nonStreamingCount += call.nonStreamingSteps
        duration += Double(call.durationMs) / 1000
        inputTokens += call.inputTokens
        cacheReadTokens += call.cacheReadTokens
        cacheWriteTokens += call.cacheWriteTokens
        outputTokens += call.outputTokens
        if let reasoning = call.reasoningTokens { reasoningTokens = (reasoningTokens ?? 0) + reasoning }
        callsWithUsage += call.callsWithUsage
        if let context = call.context { latestContext = context }
        firstTokenTotal += Double(call.firstTokenMs) / 1000
        firstTokenCount += call.firstTokenCount
        generationTime += Double(call.generationMs) / 1000
        generatedTokens += call.generatedTokens
    }
}
