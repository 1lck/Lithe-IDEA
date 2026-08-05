import Foundation

enum CommitMessageAPIProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case responses
    case chatCompletions
    case anthropicMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .responses:
            return "Responses API"
        case .chatCompletions:
            return "Chat Completions"
        case .anthropicMessages:
            return "Claude Messages API"
        }
    }

    var endpointSuffix: String {
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

enum AIProviderAuthentication: String, Codable, Sendable {
    case bearer
    case apiKey
}

enum CommitMessageReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var title: String {
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

enum CommitMessageLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
}

enum CommitMessageFormat: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case conventional
    case concise
    case imperative
    case descriptive
    case releaseNote
    case custom

    static let builtInCases: [Self] = [.conventional, .concise, .descriptive]

    static var allCases: [Self] {
        builtInCases + [.custom]
    }

    var id: String { rawValue }

    var icon: String {
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

    var title: String {
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

    var description: String {
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

    var example: String {
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

enum AIProviderCredentialSource: String, Codable, Sendable {
    case local
    case codex
    case claude

    var configurationSource: AIConfigurationSourceKind? {
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

enum AIConfigurationSourceKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var credentialSource: AIProviderCredentialSource {
        switch self {
        case .codex:
            return .codex
        case .claude:
            return .claude
        }
    }

    var detectedTitle: String {
        "\(title) configuration detected"
    }

    var apiKeyAvailableTitle: String {
        "API key available in \(title) configuration"
    }

    var noAPIKeyTitle: String {
        "No API key found in \(title) configuration"
    }

    var credentialAvailableTitle: String {
        "Credential available in \(title) configuration"
    }

    var noCredentialTitle: String {
        "No credential found in \(title) configuration"
    }

    var importTitle: String {
        "Import from \(title)"
    }

    var settingsDescription: String {
        "\(title) settings and credentials are read directly from its local configuration files."
    }
}

struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var endpoint: String
    var model: String
    var apiProtocol: CommitMessageAPIProtocol
    var authentication: AIProviderAuthentication
    var allowsInsecureHTTP: Bool
    var apiKeyIdentifier: String
    var requiresAPIKey: Bool
    var credentialSource: AIProviderCredentialSource

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

    init(
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

    var endpointURL: URL? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value)
    }

    var isValid: Bool {
        guard let url = endpointURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var usesInsecureHTTP: Bool {
        endpointURL?.scheme?.lowercased() == "http"
    }
}

struct CommitMessageAISettings: Codable, Equatable, Sendable {
    var providers: [AIProviderProfile]
    var activeProviderID: UUID?
    var reasoningEffort: CommitMessageReasoningEffort
    var language: CommitMessageLanguage
    var format: CommitMessageFormat
    var customInstructions: String
    var includeBody: Bool
    var subjectMaximumLength: Int
    var maximumDiffCharacters: Int
    var codexImportCompleted: Bool

    static var `default`: Self {
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

    var activeProvider: AIProviderProfile? {
        guard let activeProviderID else { return nil }
        return providers.first { $0.id == activeProviderID }
    }

    mutating func selectProvider(_ id: UUID?) {
        activeProviderID = id
    }

    mutating func updateActiveProvider(_ update: (inout AIProviderProfile) -> Void) {
        guard let activeProviderID,
              let index = providers.firstIndex(where: { $0.id == activeProviderID }) else {
            return
        }
        update(&providers[index])
    }

    mutating func addProvider() -> AIProviderProfile {
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

    mutating func removeActiveProvider() {
        guard let activeProviderID else { return }
        providers.removeAll { $0.id == activeProviderID }
        self.activeProviderID = providers.first?.id
    }
}

struct CommitMessageFileInput: Sendable {
    let path: String
    let changeKind: GitChangeKind
    let diff: String
}

struct CommitMessageInput: Sendable {
    let files: [CommitMessageFileInput]

    init(files: [CommitMessageFileInput]) {
        self.files = files
    }

    init(path: String, changeKind: GitChangeKind, diff: String) {
        files = [CommitMessageFileInput(path: path, changeKind: changeKind, diff: diff)]
    }

    // These accessors keep single-file callers source-compatible while the
    // generation pipeline can now represent one complete staged change set.
    var path: String {
        files.count == 1 ? (files.first?.path ?? "") : "(files.count) files"
    }

    var changeKind: GitChangeKind {
        files.count == 1 ? (files.first?.changeKind ?? .modified) : .modified
    }

    var diff: String {
        files.map(\.diff).joined(separator: "\n\n")
    }
}

struct AIConfigurationSnapshot: Identifiable, Sendable {
    let source: AIConfigurationSourceKind
    let providerName: String
    let endpoint: String
    let model: String
    let apiProtocol: CommitMessageAPIProtocol
    let authentication: AIProviderAuthentication
    let reasoningEffort: CommitMessageReasoningEffort?
    let requiresAPIKey: Bool
    let apiKey: String?

    init(
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

    var id: String { source.rawValue }

    var hasAPIKey: Bool {
        !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasCredential: Bool { hasAPIKey }
}

typealias CodexConfigurationSnapshot = AIConfigurationSnapshot
