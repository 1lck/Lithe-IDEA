import Foundation
import LitheCoreContracts

final class MacClaudeConfigurationSource: ClaudeConfigurationSource, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load() -> AIConfigurationSnapshot? {
        let home = fileManager.homeDirectoryForCurrentUser
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let credentialsURL = claudeDirectory.appendingPathComponent(".credentials.json")
        let claudeConfigURL = home.appendingPathComponent(".claude.json")

        return MacClaudeConfigurationParser.parse(
            settingsData: try? Data(contentsOf: settingsURL),
            credentialsData: try? Data(contentsOf: credentialsURL),
            rootConfigData: try? Data(contentsOf: claudeConfigURL),
            environment: ProcessInfo.processInfo.environment
        )
    }
}

enum MacClaudeConfigurationParser {
    static func parse(
        settingsData: Data?,
        credentialsData: Data?,
        rootConfigData: Data?,
        environment: [String: String]
    ) -> AIConfigurationSnapshot? {
        let settings = decodeObject(settingsData)
        let credentials = decodeObject(credentialsData)
        let rootConfig = decodeObject(rootConfigData)
        let settingsEnvironment = stringDictionary(settings?["env"])
        let combinedEnvironment = environment.merging(settingsEnvironment) { _, settingsValue in
            settingsValue
        }

        let apiKey = firstNonEmpty([
            settingsEnvironment["ANTHROPIC_API_KEY"],
            stringValue(settings?["apiKey"]),
            stringValue(rootConfig?["apiKey"]),
            stringValue(credentials?["apiKey"]),
            environment["ANTHROPIC_API_KEY"]
        ])
        let authToken = firstNonEmpty([
            settingsEnvironment["ANTHROPIC_AUTH_TOKEN"],
            stringValue(settings?["authToken"]),
            stringValue(rootConfig?["authToken"]),
            environment["ANTHROPIC_AUTH_TOKEN"]
        ])
        let credential = apiKey ?? authToken
        let authentication: AIProviderAuthentication = apiKey == nil ? .bearer : .apiKey
        let endpoint = firstNonEmpty([
            settingsEnvironment["ANTHROPIC_BASE_URL"],
            settingsEnvironment["ANTHROPIC_API_URL"],
            stringValue(settings?["apiBaseUrl"]),
            stringValue(rootConfig?["apiBaseUrl"]),
            environment["ANTHROPIC_BASE_URL"],
            "https://api.anthropic.com/v1"
        ]) ?? "https://api.anthropic.com/v1"
        let configuredModel = firstNonEmpty([
            settingsEnvironment["ANTHROPIC_MODEL"],
            stringValue(settings?["model"]),
            stringValue(rootConfig?["model"]),
            environment["ANTHROPIC_MODEL"],
            "claude-sonnet-4-5"
        ]) ?? "claude-sonnet-4-5"
        let model = resolveModelAlias(configuredModel, environment: combinedEnvironment)

        let hasConfiguration = settings != nil
            || credentials != nil
            || rootConfig != nil
            || credential != nil
            || environment["ANTHROPIC_BASE_URL"] != nil
            || environment["ANTHROPIC_API_KEY"] != nil
            || environment["ANTHROPIC_AUTH_TOKEN"] != nil
        guard hasConfiguration else { return nil }

        return AIConfigurationSnapshot(
            source: .claude,
            providerName: "Claude",
            endpoint: endpoint,
            model: model,
            apiProtocol: .anthropicMessages,
            authentication: authentication,
            reasoningEffort: nil,
            requiresAPIKey: true,
            apiKey: credential
        )
    }

    private static func decodeObject(_ data: Data?) -> [String: Any]? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String, !value.isEmpty {
                result[entry.key] = value
            }
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func resolveModelAlias(
        _ model: String,
        environment: [String: String]
    ) -> String {
        switch model.lowercased() {
        case "opus":
            return firstNonEmpty([
                environment["ANTHROPIC_DEFAULT_OPUS_MODEL"],
                environment["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"],
                model
            ]) ?? model
        case "sonnet":
            return firstNonEmpty([
                environment["ANTHROPIC_DEFAULT_SONNET_MODEL"],
                environment["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"],
                model
            ]) ?? model
        case "haiku":
            return firstNonEmpty([
                environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
                environment["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"],
                model
            ]) ?? model
        case "fable":
            return firstNonEmpty([
                environment["ANTHROPIC_DEFAULT_FABLE_MODEL"],
                environment["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"],
                model
            ]) ?? model
        default:
            return model
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
