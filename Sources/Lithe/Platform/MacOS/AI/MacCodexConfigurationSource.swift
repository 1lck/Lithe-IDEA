import Foundation

final class MacCodexConfigurationSource: CodexConfigurationSource, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load() -> CodexConfigurationSnapshot? {
        let home = fileManager.homeDirectoryForCurrentUser
        let configURL = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        let authURL = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")

        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        let authData = try? Data(contentsOf: authURL)
        guard let snapshot = MacCodexConfigurationParser.parse(config: config, authData: authData) else {
            return nil
        }
        guard !snapshot.hasAPIKey,
              let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !environmentKey.isEmpty else {
            return snapshot
        }
        return CodexConfigurationSnapshot(
            source: .codex,
            providerName: snapshot.providerName,
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            reasoningEffort: snapshot.reasoningEffort,
            requiresAPIKey: snapshot.requiresAPIKey,
            apiKey: environmentKey
        )
    }
}

enum MacCodexConfigurationParser {
    static func parse(config: String, authData: Data?) -> CodexConfigurationSnapshot? {
        var topLevel: [String: String] = [:]
        var providerValues: [String: [String: String]] = [:]
        var currentProvider: String?

        for rawLine in config.split(whereSeparator: { $0.isNewline }) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                if section.hasPrefix("model_providers.") {
                    currentProvider = String(section.dropFirst("model_providers.".count))
                    providerValues[currentProvider!, default: [:]] = [:]
                } else {
                    currentProvider = nil
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parseValue(String(parts[1]))
            if let currentProvider {
                providerValues[currentProvider, default: [:]][key] = value
            } else {
                topLevel[key] = value
            }
        }

        let providerName = topLevel["model_provider"] ?? "custom"
        guard let provider = providerValues[providerName],
              let endpoint = provider["base_url"],
              let model = topLevel["model"],
              !endpoint.isEmpty,
              !model.isEmpty else {
            return nil
        }

        let apiProtocol: CommitMessageAPIProtocol = provider["wire_api"] == "responses"
            ? .responses
            : .chatCompletions
        let reasoningEffort = topLevel["model_reasoning_effort"].flatMap {
            CommitMessageReasoningEffort(rawValue: $0)
        }
        let requiresAPIKey = provider["requires_openai_auth"] == "true"
        let apiKey = decodeAPIKey(from: authData)

        return CodexConfigurationSnapshot(
            source: .codex,
            providerName: providerName,
            endpoint: endpoint,
            model: model,
            apiProtocol: apiProtocol,
            reasoningEffort: reasoningEffort,
            requiresAPIKey: requiresAPIKey,
            apiKey: apiKey
        )
    }

    private static func parseValue(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func stripComment(_ line: String) -> String {
        var isInsideString = false
        var escaped = false
        for (index, character) in line.enumerated() {
            if character == "\\", isInsideString {
                escaped.toggle()
                continue
            }
            if character == "\"", !escaped {
                isInsideString.toggle()
            }
            if character == "#", !isInsideString {
                return String(line.prefix(index))
            }
            escaped = false
        }
        return line
    }

    private static func decodeAPIKey(from data: Data?) -> String? {
        guard let data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return values["OPENAI_API_KEY"] ?? values["api_key"]
    }
}
