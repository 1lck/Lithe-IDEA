import Foundation

/// Multiple subscription accounts per Agent. Each extra account is an isolated
/// CLI configuration directory; sign-in runs the official command in the
/// background, so Lithe never reads, copies or refreshes a credential.
extension AppModel {
    /// Application Support, never the app bundle, so account state survives updates.
    private func agentAccountsDirectory(_ agentID: String) -> URL {
        agentDataDirectory.appendingPathComponent("AgentAccounts", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
    }

    /// Annotation identity (favorites, titles, hidden rows) per workspace, Agent and
    /// account. The default account keeps the plain Agent id so existing
    /// annotations stay where they were.
    func agentHistoryIdentity(_ agentID: String) -> String {
        guard settings.agentConfigurations[agentID]?.authentication.isSubscription == true,
              let account = settings.preferredAgentAccount(for: agentID) else { return agentID }
        return "\(agentID)#\(account.id.uuidString)"
    }

    /// Create an empty account directory, then run the official sign-in for it.
    /// The account stays listed when sign-in fails or is cancelled, so it can be retried.
    func addAgentAccount(agentID: String) async throws {
        let id = UUID()
        let directory = agentAccountsDirectory(agentID).appendingPathComponent(id.uuidString, isDirectory: true)
        try services.fileStorage.createDirectory(at: directory, withIntermediateDirectories: true)
        // Numbered after the highest existing "Account N", so removals never cause a repeat.
        let used = Set(settings.agentAccounts(for: agentID).map(\.name))
        var number = settings.agentAccounts(for: agentID).count + 2
        while used.contains(String(format: String(localized: "Account %@"), String(number))) { number += 1 }
        settings.agentAccounts.append(AgentAccountProfile(
            id: id, agentID: agentID, name: String(format: String(localized: "Account %@"), String(number)),
            directoryPath: directory.path))
        try await services.agentAccountSignIn.signIn(agentID: agentID, directory: directory)
    }

    func signInAgentAccount(_ id: UUID) async throws {
        guard let account = settings.agentAccounts.first(where: { $0.id == id }) else {
            throw AgentProviderConfigurationError.unavailable
        }
        try await services.agentAccountSignIn.signIn(agentID: account.agentID, directory: account.directoryURL)
    }

    /// Switch accounts by restarting the Agent's connection with another directory.
    /// A reply in progress or a pending permission rejects the switch.
    func setPreferredAgentAccount(_ id: UUID?, agentID: String) async throws {
        guard id == nil || settings.agentAccounts(for: agentID).contains(where: { $0.id == id }) else {
            throw AgentProviderConfigurationError.unavailable
        }
        guard id != settings.preferredAgentAccountIDs[agentID] else { return }
        try beginAgentProviderChange()
        defer { finishAgentProviderChange() }
        try await stopAgentsForProviderChange([agentID])
        settings.preferredAgentAccountIDs[agentID] = id
        agentConversationFeatureIfActive?.history(for: agentID).reloadMetadata()
        agentSkillsFeature.accountDidChange()
    }

    /// Forget an account. Its directory is left on disk: it holds the CLI's login,
    /// which Lithe must not delete or inspect.
    func removeAgentAccount(_ id: UUID) async throws {
        guard let account = settings.agentAccounts.first(where: { $0.id == id }) else { return }
        if settings.preferredAgentAccountIDs[account.agentID] == id {
            try await setPreferredAgentAccount(nil, agentID: account.agentID)
        }
        settings.agentAccountSnapshots["\(account.agentID):\(id.uuidString)"] = nil
        settings.agentAccounts.removeAll { $0.id == id }
    }
}
