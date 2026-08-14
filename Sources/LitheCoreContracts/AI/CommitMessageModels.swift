import Foundation

public enum CommitMessageAPIProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case responses
    case chatCompletions
    case anthropicMessages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .responses:
            return "Responses API"
        case .chatCompletions:
            return "Chat Completions"
        case .anthropicMessages:
            return "Claude Messages API"
        }
    }

    public var endpointSuffix: String {
        switch self {
        case .responses:
            return "responses"
        case .chatCompletions:
            return "chat/completions"
        case .anthropicMessages:
            return "messages"
        }
    }
}

public enum AIProviderAuthentication: String, Codable, Sendable {
    case bearer
    case apiKey
}

public enum CommitMessageReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none:
            return "None (fastest)"
        case .low:
            return "Low (recommended)"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "XHigh"
        case .max:
            return "Max"
        }
    }
}

public enum CommitMessageLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english
    case simplifiedChinese

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
}

public enum CommitMessageFormat: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case conventional
    case concise
    case imperative
    case descriptive
    case releaseNote
    case custom

    public static let builtInCases: [Self] = [.conventional, .concise, .descriptive]

    public static var allCases: [Self] {
        builtInCases + [.custom]
    }

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .conventional:
            return "number"
        case .concise:
            return "text.alignleft"
        case .imperative:
            return "arrow.right"
        case .descriptive:
            return "text.justify.leading"
        case .releaseNote:
            return "megaphone"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    public var title: String {
        switch self {
        case .conventional:
            return "Conventional Commits"
        case .concise:
            return "Concise sentence"
        case .imperative:
            return "Imperative subject"
        case .descriptive:
            return "Detailed subject + body"
        case .releaseNote:
            return "Release note"
        case .custom:
            return "Custom instructions"
        }
    }

    public var description: String {
        switch self {
        case .conventional:
            return "Structured type(scope): subject format"
        case .concise:
            return "One sentence focused on the main change"
        case .imperative:
            return "Start with an action verb, without a type prefix"
        case .descriptive:
            return "A detailed message with a clear subject and body"
        case .releaseNote:
            return "User-facing sentence for release notes"
        case .custom:
            return "Follow the instructions you define below"
        }
    }

    public var example: String {
        switch self {
        case .conventional:
            return "feat(editor): add memory usage indicator"
        case .concise:
            return "Add a memory usage indicator to the status bar"
        case .imperative:
            return "Add memory usage visibility to the status bar"
        case .descriptive:
            return "Add memory usage monitoring\n\nTrack current and average memory usage in the status bar."
        case .releaseNote:
            return "Added memory usage visibility to the status bar."
        case .custom:
            return "Follow the instructions you define below"
        }
    }
}

public enum AIProviderCredentialSource: String, Codable, Sendable {
    case local
    case codex
    case claude

    public var configurationSource: AIConfigurationSourceKind? {
        switch self {
        case .local:
            return nil
        case .codex:
            return .codex
        case .claude:
            return .claude
        }
    }
}

public enum AIConfigurationSourceKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    public var credentialSource: AIProviderCredentialSource {
        switch self {
        case .codex:
            return .codex
        case .claude:
            return .claude
        }
    }

    public var detectedTitle: String {
        "\(title) configuration detected"
    }

    public var apiKeyAvailableTitle: String {
        "API key available in \(title) configuration"
    }

    public var noAPIKeyTitle: String {
        "No API key found in \(title) configuration"
    }

    public var credentialAvailableTitle: String {
        "Credential available in \(title) configuration"
    }

    public var noCredentialTitle: String {
        "No credential found in \(title) configuration"
    }

    public var importTitle: String {
        "Import from \(title)"
    }

    public var settingsDescription: String {
        "\(title) settings and credentials are read directly from its local configuration files."
    }
}

public struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var endpoint: String
    public var model: String
    public var apiProtocol: CommitMessageAPIProtocol
    public var authentication: AIProviderAuthentication
    public var allowsInsecureHTTP: Bool
    public var apiKeyIdentifier: String
    public var requiresAPIKey: Bool
    public var credentialSource: AIProviderCredentialSource

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case endpoint
        case model
        case apiProtocol
        case authentication
        case allowsInsecureHTTP
        case apiKeyIdentifier
        case requiresAPIKey
        case credentialSource
    }

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        model: String,
        apiProtocol: CommitMessageAPIProtocol,
        authentication: AIProviderAuthentication? = nil,
        allowsInsecureHTTP: Bool = false,
        apiKeyIdentifier: String? = nil,
        requiresAPIKey: Bool = true,
        credentialSource: AIProviderCredentialSource = .local
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.apiProtocol = apiProtocol
        self.authentication = authentication
            ?? (apiProtocol == .anthropicMessages ? .apiKey : .bearer)
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.apiKeyIdentifier = apiKeyIdentifier ?? "lithe.ai-provider.\(id.uuidString)"
        self.requiresAPIKey = requiresAPIKey
        self.credentialSource = credentialSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        model = try container.decode(String.self, forKey: .model)
        apiProtocol = try container.decode(CommitMessageAPIProtocol.self, forKey: .apiProtocol)
        authentication = try container.decodeIfPresent(
            AIProviderAuthentication.self,
            forKey: .authentication
        ) ?? (apiProtocol == .anthropicMessages ? .apiKey : .bearer)
        allowsInsecureHTTP = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsInsecureHTTP
        ) ?? false
        apiKeyIdentifier = try container.decode(String.self, forKey: .apiKeyIdentifier)
        requiresAPIKey = try container.decode(Bool.self, forKey: .requiresAPIKey)
        credentialSource = try container.decodeIfPresent(
            AIProviderCredentialSource.self,
            forKey: .credentialSource
        ) ?? .local
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(model, forKey: .model)
        try container.encode(apiProtocol, forKey: .apiProtocol)
        try container.encode(authentication, forKey: .authentication)
        try container.encode(allowsInsecureHTTP, forKey: .allowsInsecureHTTP)
        try container.encode(apiKeyIdentifier, forKey: .apiKeyIdentifier)
        try container.encode(requiresAPIKey, forKey: .requiresAPIKey)
        try container.encode(credentialSource, forKey: .credentialSource)
    }

    public var endpointURL: URL? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value)
    }

    public var isValid: Bool {
        guard let url = endpointURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    public var usesInsecureHTTP: Bool {
        endpointURL?.scheme?.lowercased() == "http"
    }
}

public struct CommitMessageAISettings: Codable, Equatable, Sendable {
    public var providers: [AIProviderProfile]
    public var activeProviderID: UUID?
    public var reasoningEffort: CommitMessageReasoningEffort
    public var language: CommitMessageLanguage
    public var format: CommitMessageFormat
    public var customInstructions: String
    public var includeBody: Bool
    public var subjectMaximumLength: Int
    public var maximumDiffCharacters: Int
    public var codexImportCompleted: Bool

    public static var `default`: Self {
        Self(
            providers: [],
            activeProviderID: nil,
            reasoningEffort: .low,
            language: .english,
            format: .conventional,
            customInstructions: "",
            includeBody: false,
            subjectMaximumLength: 72,
            maximumDiffCharacters: 32_000,
            codexImportCompleted: false
        )
    }

    public var activeProvider: AIProviderProfile? {
        guard let activeProviderID else { return nil }
        return providers.first { $0.id == activeProviderID }
    }

    public mutating func selectProvider(_ id: UUID?) {
        activeProviderID = id
    }

    public mutating func updateActiveProvider(_ update: (inout AIProviderProfile) -> Void) {
        guard let activeProviderID,
              let index = providers.firstIndex(where: { $0.id == activeProviderID }) else {
            return
        }
        update(&providers[index])
    }

    public mutating func addProvider() -> AIProviderProfile {
        let provider = AIProviderProfile(
            name: "Custom Provider",
            endpoint: "",
            model: "",
            apiProtocol: .responses,
            requiresAPIKey: true
        )
        providers.append(provider)
        activeProviderID = provider.id
        return provider
    }

    public mutating func removeActiveProvider() {
        guard let activeProviderID else { return }
        providers.removeAll { $0.id == activeProviderID }
        self.activeProviderID = providers.first?.id
    }
}

public struct AIConfigurationSnapshot: Identifiable, Sendable {
    public let source: AIConfigurationSourceKind
    public let providerName: String
    public let endpoint: String
    public let model: String
    public let apiProtocol: CommitMessageAPIProtocol
    public let authentication: AIProviderAuthentication
    public let reasoningEffort: CommitMessageReasoningEffort?
    public let requiresAPIKey: Bool
    public let apiKey: String?

    public init(
        source: AIConfigurationSourceKind = .codex,
        providerName: String,
        endpoint: String,
        model: String,
        apiProtocol: CommitMessageAPIProtocol,
        authentication: AIProviderAuthentication = .bearer,
        reasoningEffort: CommitMessageReasoningEffort?,
        requiresAPIKey: Bool,
        apiKey: String?
    ) {
        self.source = source
        self.providerName = providerName
        self.endpoint = endpoint
        self.model = model
        self.apiProtocol = apiProtocol
        self.authentication = authentication
        self.reasoningEffort = reasoningEffort
        self.requiresAPIKey = requiresAPIKey
        self.apiKey = apiKey
    }

    public var id: String { source.rawValue }

    public var hasAPIKey: Bool {
        !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public var hasCredential: Bool { hasAPIKey }
}

public typealias CodexConfigurationSnapshot = AIConfigurationSnapshot
