import Foundation

/// Account-owned subscription windows, separate from session context occupancy.
public struct AgentSubscriptionQuota: Decodable, Equatable, Sendable {
    public struct Window: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let limitSeconds: UInt64
        public let usedPercent: Double?
        public let resetsAt: Int64?

        public init(id: String, name: String, limitSeconds: UInt64, usedPercent: Double?, resetsAt: Int64?) {
            self.id = id
            self.name = name
            self.limitSeconds = limitSeconds
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    /// Who reports the windows. Codex is polled by the Host; Claude Code reports
    /// a window only while a reply runs, so its snapshot is never "refreshed".
    public enum Source: Equatable, Sendable { case codex, claude }

    public let windows: [Window]
    public let fetchedAt: UInt64
    public var source: Source = .codex

    private enum CodingKeys: String, CodingKey { case windows, fetchedAt }

    public init(windows: [Window], fetchedAt: UInt64, source: Source) {
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public var mostUsedWindow: Window? {
        windows.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    public func isStale(at now: Date) -> Bool {
        let reset = windows.contains { $0.resetsAt.map { Double($0) <= now.timeIntervalSince1970 } ?? false }
        // A passive Claude snapshot stays valid until a window resets.
        return source == .claude ? reset : now.timeIntervalSince1970 - Double(fetchedAt) > 120 || reset
    }

    /// Fold one Claude Code `rate_limit_info` into the account's windows. Each
    /// report names one window (`rateLimitType`) with `utilization` as a 0–1
    /// fraction and `resetsAt` in Unix seconds; unknown or overage reports are
    /// ignored rather than guessed.
    public func mergingClaudeRateLimit(_ info: [String: Any], at now: Date) -> Self? {
        Self.claudeWindow(info).map { window in
            let kept = source == .claude ? windows.filter { $0.id != window.id } : []
            return Self(windows: (kept + [window]).sorted { $0.id < $1.id },
                        fetchedAt: UInt64(max(0, now.timeIntervalSince1970)), source: .claude)
        }
    }

    public static func claudeRateLimit(_ info: [String: Any], at now: Date) -> Self? {
        claudeWindow(info).map { Self(windows: [$0], fetchedAt: UInt64(max(0, now.timeIntervalSince1970)), source: .claude) }
    }

    private static func claudeWindow(_ info: [String: Any]) -> Window? {
        let kinds: [String: (name: String, seconds: UInt64)] = [
            "five_hour": ("claude", 5 * 3_600), "seven_day": ("claude", 7 * 86_400),
            "seven_day_opus": ("Opus", 7 * 86_400), "seven_day_sonnet": ("Sonnet", 7 * 86_400),
        ]
        guard let type = info["rateLimitType"] as? String, let kind = kinds[type] else { return nil }
        let utilization = (info["utilization"] as? NSNumber)?.doubleValue
        let used = utilization.flatMap { $0.isFinite && (0...1).contains($0) ? $0 * 100 : nil }
        let reset = (info["resetsAt"] as? NSNumber)?.int64Value
        return Window(id: type, name: kind.name, limitSeconds: kind.seconds, usedPercent: used, resetsAt: reset)
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
