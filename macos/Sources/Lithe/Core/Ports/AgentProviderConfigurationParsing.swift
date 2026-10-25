import Foundation
import LitheModuleAPI
import LitheCoreContracts

/// Parses an explicit editor draft. No filesystem discovery or environment fallback.
protocol AgentProviderConfigurationParsing: Sendable {
    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String, allowIncomplete: Bool) throws -> AIConfigurationSnapshot
}

extension AgentProviderConfigurationParsing {
    /// Saving requires a complete provider; switching presentation can read incomplete input.
    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String) throws -> AIConfigurationSnapshot {
        try parse(source: source, configuration: configuration, authentication: authentication, allowIncomplete: false)
    }
}

enum AgentProviderConfigurationError: LocalizedError, Equatable {
    case invalidConfiguration, invalidConfigurationQuotes, invalidAuthentication, missingAPIKey, missingModel, invalidName, invalidEndpoint, insecureHTTP, unsupportedProtocol, busy, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: L10n.string("Check the configuration format, API URL and model. Each configuration must be under 64 KiB.")
        case .invalidConfigurationQuotes: L10n.string("Invalid TOML. Use straight quotes (\") instead of smart quotes (“ ”).")
        case .invalidAuthentication: L10n.string("Authentication must be a JSON object containing an OPENAI_API_KEY string.")
        case .missingAPIKey: L10n.string("Enter an API key. CLI login credentials cannot be used as an API key.")
        case .missingModel: L10n.string("Enter a model ID supported by your provider.")
        case .invalidName: L10n.string("Enter a provider name.")
        case .invalidEndpoint: L10n.string("Enter an HTTP or HTTPS API URL without credentials, query parameters or fragments.")
        case .insecureHTTP: L10n.string("HTTP is blocked until you explicitly allow it for this provider.")
        case .unsupportedProtocol: L10n.string("Codex Agents require the Responses API. Claude Agents require an Anthropic API key.")
        case .busy: L10n.string("Wait for the Agent operation to finish before changing providers.")
        case .unavailable: L10n.string("Provider configuration parsing is unavailable.")
        }
    }
}

struct UnavailableAgentProviderConfigurationParser: AgentProviderConfigurationParsing {
    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String, allowIncomplete: Bool) throws -> AIConfigurationSnapshot {
        throw AgentProviderConfigurationError.unavailable
    }
}
