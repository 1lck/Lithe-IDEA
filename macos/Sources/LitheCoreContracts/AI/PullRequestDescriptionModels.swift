import Foundation

public enum PullRequestDescriptionFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case concise
    case detailed
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .concise: "Concise"
        case .detailed: "Detailed"
        case .custom: "Custom template"
        }
    }
}

public struct PullRequestDescriptionFileInput: Equatable, Sendable {
    public let path: String
    public let changeKind: CommitMessageChangeKind
    public let patch: String

    public init(path: String, changeKind: CommitMessageChangeKind, patch: String) {
        self.path = path
        self.changeKind = changeKind
        self.patch = patch
    }
}

public struct PullRequestDescriptionInput: Equatable, Sendable {
    public let repository: String
    public let base: String
    public let head: String
    public let commitMessages: [String]
    public let files: [PullRequestDescriptionFileInput]

    public init(
        repository: String,
        base: String,
        head: String,
        commitMessages: [String],
        files: [PullRequestDescriptionFileInput]
    ) {
        self.repository = repository
        self.base = base
        self.head = head
        self.commitMessages = commitMessages
        self.files = files
    }
}

public struct PullRequestDescriptionOutput: Codable, Equatable, Sendable {
    public let title: String
    public let description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

public enum PullRequestDescriptionGenerationError: LocalizedError, Sendable {
    case emptyComparison
    case invalidResponse
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .emptyComparison:
            String(localized: "The selected branches have no textual changes to summarize.")
        case .invalidResponse:
            String(localized: "The AI provider returned an unexpected pull request description.")
        case .emptyResponse:
            String(localized: "The AI provider returned an empty pull request description.")
        }
    }
}
