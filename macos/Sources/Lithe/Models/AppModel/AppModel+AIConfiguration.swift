import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    @discardableResult
    func refreshAIConfigurations() -> Bool {
        let configurations = loadAIConfigurations()
        detectedAIConfigurations = configurations
        guard let activeProvider = settings.activeCommitMessageProvider,
              let source = configurationSource(for: activeProvider),
              let configuration = configurations.first(where: { $0.source == source }) else {
            return !configurations.isEmpty
        }
        updateImportedProvider(from: configuration)
        return true
    }

    @discardableResult
    func refreshCodexConfiguration() -> Bool {
        refreshAIConfigurations()
        return detectedCodexConfiguration != nil
    }

    @discardableResult
    func importAIConfiguration(_ configuration: AIConfigurationSnapshot) -> Bool {
        let provider = settings.importAIConfiguration(configuration)
        try? services.secureStore.delete(key: provider.apiKeyIdentifier)
        detectedAIConfigurations.removeAll { $0.source == configuration.source }
        detectedAIConfigurations.append(configuration)
        enableAIAssistanceModule()
        showNotification("\(configuration.source.title) configuration imported")
        return true
    }

    @discardableResult
    func importCodexConfiguration() -> Bool {
        guard let configuration = loadAIConfigurations().first(where: { $0.source == .codex }) else {
            detectedAIConfigurations.removeAll { $0.source == .codex }
            showNotification("No Codex configuration was found")
            return false
        }
        return importAIConfiguration(configuration)
    }

    var activeCommitMessageAPIKey: String {
        guard let provider = settings.activeCommitMessageProvider else { return "" }
        return services.credentialResolver.readAPIKey(for: provider) ?? ""
    }

    var activeCommitMessageCredentialIsConfigurationManaged: Bool {
        guard let provider = settings.activeCommitMessageProvider else { return false }
        return configurationSource(for: provider) != nil
    }

    var activeCommitMessageConfigurationSourceTitle: String? {
        settings.activeCommitMessageProvider.flatMap(configurationSource(for:))?.title
    }

    var activeCommitMessageConfigurationSourceDescription: String? {
        settings.activeCommitMessageProvider.flatMap(configurationSource(for:))?.settingsDescription
    }

    var activeCommitMessageCredentialIsCodexManaged: Bool {
        activeCommitMessageCredentialIsConfigurationManaged
    }

    func saveActiveCommitMessageAPIKey(_ value: String) {
        guard let provider = settings.activeCommitMessageProvider else { return }
        if activeCommitMessageCredentialIsConfigurationManaged {
            showNotification("API key is managed by \(activeCommitMessageConfigurationSourceTitle ?? "AI") configuration")
            return
        }
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { try services.secureStore.delete(key: provider.apiKeyIdentifier) }
            else {
                try services.secureStore.write(trimmed, key: provider.apiKeyIdentifier)
                enableAIAssistanceModule()
            }
            showNotification("API key saved locally")
        } catch { showNotification(error.localizedDescription) }
    }

    func loadAIConfigurations() -> [AIConfigurationSnapshot] {
        services.aiConfigurationSources.compactMap { $0.load() }
    }

    private func configurationSource(for provider: AIProviderProfile) -> AIConfigurationSourceKind? {
        if let source = provider.credentialSource.configurationSource { return source }
        if provider.apiKeyIdentifier == "lithe.codex.imported.apiKey" { return .codex }
        if provider.apiKeyIdentifier == "lithe.claude.imported.apiKey" { return .claude }
        return nil
    }

    private func updateImportedProvider(from configuration: AIConfigurationSnapshot) {
        guard let activeProvider = settings.activeCommitMessageProvider,
              configurationSource(for: activeProvider) == configuration.source else { return }
        settings.updateActiveCommitMessageProvider { provider in
            provider.name = configuration.providerName.isEmpty ? "\(configuration.source.title) (imported)" : "\(configuration.source.title) · \(configuration.providerName)"
            provider.endpoint = configuration.endpoint
            provider.model = configuration.model
            provider.apiProtocol = configuration.apiProtocol
            provider.authentication = configuration.authentication
            provider.requiresAPIKey = configuration.requiresAPIKey
            provider.apiKeyIdentifier = "lithe.\(configuration.source.rawValue).imported.apiKey"
            provider.credentialSource = configuration.source.credentialSource
        }
        try? services.secureStore.delete(key: "lithe.\(configuration.source.rawValue).imported.apiKey")
    }

    private func enableAIAssistanceModule() {
        Task { @MainActor in
            do {
                try await services.moduleRuntime.setEnabled(true, for: .aiAssistance)
                objectWillChange.send()
            } catch {
                showNotification(error.localizedDescription)
            }
        }
    }
}
