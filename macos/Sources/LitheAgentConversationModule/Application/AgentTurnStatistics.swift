import Foundation

/// Token counters from a prompt response. The Agent owns their accounting scope;
/// context occupancy and subscription quota are separate measurements.
public struct AgentTurnUsage: Codable, Equatable, Sendable {
    public let totalTokens: UInt64
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let thoughtTokens: UInt64?
    public let cachedReadTokens: UInt64?
    public let cachedWriteTokens: UInt64?

    static func parse(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// In-memory timing of a locally submitted turn, including session preparation,
/// tools and permission waits. A monotonic clock prevents wall-clock changes.
public struct AgentTurnStatistics: Identifiable, Equatable, Sendable {
    public let id: String
    public let startedAt: ContinuousClock.Instant
    public private(set) var endingMessageID: String?
    public private(set) var duration: TimeInterval?
    /// Wall-clock time the turn ended, shown beside the reply. Durations stay
    /// on the monotonic clock; this is only a label.
    public private(set) var completedAt: Date?
    public private(set) var usage: AgentTurnUsage?
    /// Tool calls the Agent reported during this turn.
    public private(set) var toolCallCount = 0
    /// Locally observed time with a running tool or a pending permission.
    public private(set) var toolDuration: TimeInterval = 0
    /// Provider requests observed by the optional Host proxy.
    public private(set) var modelCalls = AgentModelCallTotals()
    private var toolsRunningSince: ContinuousClock.Instant?

    public init(id: String, startedAt: ContinuousClock.Instant) {
        self.id = id
        self.startedAt = startedAt
    }

    public func elapsed(at instant: ContinuousClock.Instant) -> TimeInterval {
        if let duration { return duration }
        let components = startedAt.duration(to: instant).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    mutating func finish(at instant: ContinuousClock.Instant, endingMessageID: String, usage: AgentTurnUsage?,
                         toolCallCount: Int = 0, completedAt: Date = Date()) {
        setToolsRunning(false, at: instant)
        duration = elapsed(at: instant)
        self.completedAt = completedAt
        self.endingMessageID = endingMessageID
        self.usage = usage
        self.toolCallCount = toolCallCount
    }

    /// Open or close the interval in which the Agent waits on tools or the user.
    /// Overlapping tools and permissions count once.
    mutating func setToolsRunning(_ running: Bool, at instant: ContinuousClock.Instant) {
        switch (running, toolsRunningSince) {
        case (true, nil):
            toolsRunningSince = instant
        case (false, let since?):
            let components = since.duration(to: instant).components
            toolDuration += max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
            toolsRunningSince = nil
        default:
            break
        }
    }

    mutating func recordModelCall(_ call: AgentModelCall) {
        modelCalls.record(call)
    }
}
