import Foundation
import LitheCoreContracts

final class MacAIProviderCredentialResolver: AIProviderCredentialResolver, @unchecked Sendable {
    private let localStore: any SecureStore
    private let configurationSources: [any AIConfigurationSource]

    init(
        localStore: any SecureStore,
        configurationSources: [any AIConfigurationSource]
    ) {
        self.localStore = localStore
        self.configurationSources = configurationSources
    }

    convenience init(
        localStore: any SecureStore,
        codexConfigurationSource: any CodexConfigurationSource
    ) {
        self.init(
            localStore: localStore,
            configurationSources: [codexConfigurationSource]
        )
    }

    func readAPIKey(for provider: AIProviderProfile) -> String? {
        switch provider.credentialSource {
        case .local:
            return localStore.read(key: provider.apiKeyIdentifier)
        case .codex, .claude:
            guard let sourceKind = provider.credentialSource.configurationSource else {
                return nil
            }
            return configurationSources
                .compactMap { $0.load() }
                .first { $0.source == sourceKind }?
                .apiKey
        }
    }
}
