import Foundation

/// Agent-reported context occupancy, distinct from cumulative billing tokens.
public struct AgentContextUsage: Equatable, Sendable {
    public let usedTokens: UInt64
    public let capacityTokens: UInt64

    public init?(usedTokens: UInt64, capacityTokens: UInt64) {
        guard capacityTokens > 0 else { return nil }
        self.usedTokens = usedTokens
        self.capacityTokens = capacityTokens
    }

    /// Preserve the reported values even if occupancy exceeds the window size.
    public var fraction: Double { Double(usedTokens) / Double(capacityTokens) }

    static func parse(_ update: [String: Any]) -> Self? {
        struct Payload: Decodable { let used: UInt64; let size: UInt64 }
        guard let data = try? JSONSerialization.data(withJSONObject: update),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return Self(usedTokens: payload.used, capacityTokens: payload.size)
    }
}
