import Foundation
import LitheAgentConversationModule

/// One extra account of an Agent's official subscription. Its directory is an
/// isolated configuration directory (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`) that
/// only the official CLI reads and writes.
struct AgentAccountProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var agentID: String
    var name: String
    var directoryPath: String

    var directoryURL: URL { URL(fileURLWithPath: directoryPath, isDirectory: true) }
}

/// What the adapter last reported for an account. Never refreshed by Lithe.
struct AgentAccountSnapshot: Codable, Equatable {
    var email: String?
    var plan: String?
    var quota: AgentSubscriptionQuota?
    var observedAt: Date
}

extension AppSettings {
    /// Key of an Agent's own default account in `agentAccountSnapshots`.
    static func defaultAgentAccountKey(_ agentID: String) -> String { "\(agentID):default" }

    func agentAccounts(for agentID: String) -> [AgentAccountProfile] {
        agentAccounts.filter { $0.agentID == agentID }
    }

    /// Snapshot key for a launch directory; `nil` or an unknown directory is the default account.
    func agentAccountKey(agentID: String, directory: URL?) -> String {
        guard let directory else { return Self.defaultAgentAccountKey(agentID) }
        let path = directory.standardizedFileURL.path
        return agentAccounts(for: agentID).first { $0.directoryURL.standardizedFileURL.path == path }
            .map { "\(agentID):\($0.id.uuidString)" } ?? Self.defaultAgentAccountKey(agentID)
    }

    /// The account new connections of this Agent use; `nil` is the CLI's default.
    func preferredAgentAccount(for agentID: String) -> AgentAccountProfile? {
        preferredAgentAccountIDs[agentID].flatMap { id in
            agentAccounts(for: agentID).first { $0.id == id }
        }
    }

    /// The directory a new connection of this Agent is launched with.
    func preferredAgentAccountDirectory(for agentID: String) -> URL? {
        preferredAgentAccount(for: agentID)?.directoryURL
    }

    func recordAgentAccount(agentID: String, directory: URL?, email: String?, plan: String?,
                            quota: AgentSubscriptionQuota?) {
        let key = agentAccountKey(agentID: agentID, directory: directory)
        var snapshot = agentAccountSnapshots[key] ?? AgentAccountSnapshot(observedAt: Date())
        snapshot.email = email ?? snapshot.email
        snapshot.plan = plan ?? snapshot.plan
        if let quota { snapshot.quota = quota; snapshot.observedAt = Date(timeIntervalSince1970: TimeInterval(quota.fetchedAt)) }
        guard snapshot != agentAccountSnapshots[key] else { return }
        agentAccountSnapshots[key] = snapshot
    }
}
