import Foundation
import LitheCoreContracts

/// Parses an explicit editor draft. No filesystem discovery or environment fallback.
protocol AgentProviderConfigurationParsing: Sendable {
    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String) throws -> AIConfigurationSnapshot
}

enum AgentProviderConfigurationError: LocalizedError, Equatable {
    case invalidConfiguration, invalidConfigurationQuotes, invalidAuthentication, missingAPIKey, invalidName, invalidEndpoint, insecureHTTP, unsupportedProtocol, busy, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "Check the configuration format, API URL and model. Each configuration must be under 64 KiB.")
        case .invalidConfigurationQuotes: String(localized: "Invalid TOML. Use straight quotes (\") instead of smart quotes (“ ”).")
        case .invalidAuthentication: String(localized: "Authentication must be a JSON object containing an OPENAI_API_KEY string.")
        case .missingAPIKey: String(localized: "Enter an API key. CLI login credentials cannot be used as an API key.")
        case .invalidName: String(localized: "Enter a provider name.")
        case .invalidEndpoint: String(localized: "Enter an HTTP or HTTPS API URL without credentials, query parameters or fragments.")
        case .insecureHTTP: String(localized: "HTTP is blocked until you explicitly allow it for this provider.")
        case .unsupportedProtocol: String(localized: "Codex Agents require the Responses API. Claude Agents require an Anthropic API key.")
        case .busy: String(localized: "Wait for the Agent operation to finish before changing providers.")
        case .unavailable: String(localized: "Provider configuration parsing is unavailable.")
        }
    }
}

struct UnavailableAgentProviderConfigurationParser: AgentProviderConfigurationParsing {
    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String) throws -> AIConfigurationSnapshot {
        throw AgentProviderConfigurationError.unavailable
    }
}
