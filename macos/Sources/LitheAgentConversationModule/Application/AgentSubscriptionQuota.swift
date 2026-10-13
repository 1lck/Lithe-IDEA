import Foundation

/// Account-owned subscription windows, separate from session context occupancy.
public struct AgentSubscriptionQuota: Decodable, Equatable, Sendable {
    public struct Window: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let limitSeconds: UInt64
        public let usedPercent: Double?
        public let resetsAt: Int64?
    }

    public let windows: [Window]
    public let fetchedAt: UInt64

    public var mostUsedWindow: Window? {
        windows.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince1970 - Double(fetchedAt) > 120 || windows.contains {
            $0.resetsAt.map { Double($0) <= now.timeIntervalSince1970 } ?? false
        }
    }

    static func parse(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              !result.windows.isEmpty, result.windows.allSatisfy({ window in
                  window.limitSeconds > 0 && (window.usedPercent.map { $0.isFinite && (0...100).contains($0) } ?? true)
              }) else { return nil }
        return result
    }
}
