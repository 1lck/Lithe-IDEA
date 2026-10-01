import Foundation

/// Token counters from a prompt response. The Agent owns their accounting scope;
/// context occupancy and subscription quota are separate measurements.
public struct AgentTurnUsage: Decodable, Equatable, Sendable {
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
    public private(set) var usage: AgentTurnUsage?

    public init(id: String, startedAt: ContinuousClock.Instant) {
        self.id = id
        self.startedAt = startedAt
    }

    public func elapsed(at instant: ContinuousClock.Instant) -> TimeInterval {
        if let duration { return duration }
        let components = startedAt.duration(to: instant).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    mutating func finish(at instant: ContinuousClock.Instant, endingMessageID: String, usage: AgentTurnUsage?) {
        duration = elapsed(at: instant)
        self.endingMessageID = endingMessageID
        self.usage = usage
    }
}
