import Foundation

/// A live ACP advisory, kept apart from replies and exported conversation history.
public struct AgentSessionNotice: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable { case info, warning, error }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String?

    // Claude ACP 0.81.2 has no machine-readable notice code. Match its structured
    // title only on the Claude connection; never classify assistant prose.
    var isClaudeAutoModeFallback: Bool { severity == .warning && title == "Auto mode unavailable" }
    static let claudeAutoMode = "auto"
    static let claudeAutoFallbackMode = "acceptEdits"

    static func parse(_ update: [String: Any]) -> Self? {
        guard let rawSeverity = update["severity"] as? String,
              let severity = Severity(rawValue: rawSeverity),
              let title = update["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self(id: UUID().uuidString, severity: severity, title: String(title.prefix(256)),
                    detail: (update["description"] as? String).map { String($0.prefix(4096)) })
    }
}

/// Identifies the old advisory before an upstream Auto downgrade. Only a new
/// notice from this transition survives the next complete configuration snapshot.
struct AgentAutoFallbackTransition: Equatable, Sendable {
    let precedingNoticeID: String?
}
