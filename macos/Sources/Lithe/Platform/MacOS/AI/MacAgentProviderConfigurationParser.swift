import Foundation
import LitheCoreContracts

/// Shared Rust Core parsing of pasted CLI configuration plus native, ephemeral credential extraction.
///
/// Core returns metadata and a credential locator only; this adapter resolves the
/// locator against the text the user pasted, so the key never crosses the Core boundary.
struct MacAgentProviderConfigurationParser: AgentProviderConfigurationParsing {
    let core: RustCoreBridge

    private struct Files: Encodable {
        var config: String?
        var auth: String?
        var settings: String?
    }
    private struct Payload: Encodable {
        let source: String
        let files: Files
        let allowIncomplete: Bool
    }
    private struct Locator: Decodable {
        let kind: String
        let file: String?
        let path: [String]?
    }
    private struct Response: Decodable {
        struct Provider: Decodable {
            let name: String
            let endpoint: String
            let model: String
            let apiProtocol: CommitMessageAPIProtocol
            let authentication: AIProviderAuthentication
        }
        let provider: Provider?
        let hasCredential: Bool
        let credential: Locator?
        let unsupportedAuthentication: Bool
    }

    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String, allowIncomplete: Bool) throws -> AIConfigurationSnapshot {
        guard configuration.utf8.count <= 64 * 1024, authentication.utf8.count <= 64 * 1024 else {
            throw AgentProviderConfigurationError.invalidConfiguration
        }
        let files: Files
        switch source {
        case .codex: files = Files(config: configuration, auth: authentication)
        case .claude: files = Files(settings: configuration)
        }
        let response: Response?
        do {
            response = try core.executeResult(command: "ai.configuration.parse", payload: Payload(
                source: source.rawValue, files: files, allowIncomplete: allowIncomplete
            )).get()
        } catch let error as RustCoreBridge.CoreCallError {
            // Fixed codes only: parser diagnostics could quote a pasted credential.
            if error.message == "AI_CONFIGURATION_SMART_QUOTES" { throw AgentProviderConfigurationError.invalidConfigurationQuotes }
            if error.message == "AI_CONFIGURATION_INVALID_AUTHENTICATION" { throw AgentProviderConfigurationError.invalidAuthentication }
            throw AgentProviderConfigurationError.invalidConfiguration
        } catch {
            throw AgentProviderConfigurationError.invalidConfiguration
        }
        guard let response else {
            // Strict Claude parsing reports "not configured" as no data; the editor asks for a key.
            throw source == .claude && !allowIncomplete
                ? AgentProviderConfigurationError.missingAPIKey
                : AgentProviderConfigurationError.invalidConfiguration
        }
        guard let provider = response.provider else {
            throw AgentProviderConfigurationError.invalidConfiguration
        }
        let key = Self.resolve(response.credential, files: files)
        switch source {
        case .codex:
            // A saved Codex provider must carry the pasted `auth.json` key.
            if !allowIncomplete, key == nil { throw AgentProviderConfigurationError.invalidAuthentication }
        case .claude:
            if !allowIncomplete, key == nil { throw AgentProviderConfigurationError.missingAPIKey }
            guard provider.authentication == .apiKey, !response.unsupportedAuthentication else {
                throw AgentProviderConfigurationError.unsupportedProtocol
            }
        }
        return AIConfigurationSnapshot(source: source, providerName: provider.name, endpoint: provider.endpoint,
            model: provider.model, apiProtocol: provider.apiProtocol, authentication: provider.authentication,
            reasoningEffort: nil, requiresAPIKey: true, apiKey: key ?? "")
    }

    /// Reads the value a file locator names from the pasted JSON; draft parsing never consults the environment.
    private static func resolve(_ locator: Locator?, files: Files) -> String? {
        guard let locator, locator.kind == "file", let path = locator.path else { return nil }
        let text: String?
        switch locator.file {
        case "auth": text = files.auth
        case "settings": text = files.settings
        default: text = nil
        }
        guard let text, var value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        for key in path {
            guard let object = value as? [String: Any], let next = object[key] else { return nil }
            value = next
        }
        return value as? String
    }
}
