import Foundation

public struct GitHubRepository: Codable, Equatable, Hashable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }
}

public struct GitHubUser: Codable, Equatable, Hashable, Sendable {
    public let login: String
    public let url: String
    public let avatarURL: String?

    public init(login: String, url: String, avatarURL: String?) {
        self.login = login
        self.url = url
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case login, url
        case avatarURL = "avatarUrl"
    }
}

public struct GitHubLabel: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let color: String?

    public init(name: String, color: String?) {
        self.name = name
        self.color = color
    }
}

public struct GitHubPullRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64 { number }
    public let number: UInt64
    public let title: String
    public let body: String
    public let state: String
    public let isDraft: Bool
    public let url: String
    public let author: GitHubUser
    public let headRef: String
    public let headRepository: String?
    public let baseRef: String
    public let baseRepository: String?
    public let createdAt: String
    public let updatedAt: String
    public let isMerged: Bool
    public let isMergeable: Bool?
    public let additions: UInt64?
    public let deletions: UInt64?
    public let changedFiles: UInt64?
    public let commentsCount: UInt64
    public let labels: [GitHubLabel]
    public let assignees: [GitHubUser]
}

public struct GitHubComment: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let author: GitHubUser
    public let body: String
    public let createdAt: String
    public let updatedAt: String
    public let url: String
}

public struct GitHubPullRequestFile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
    public let additions: UInt64
    public let deletions: UInt64
    public let patch: String?
}

public struct GitHubDeviceAuthorization: Codable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    public let expiresIn: UInt64
    public let interval: UInt64

    private enum CodingKeys: String, CodingKey {
        case deviceCode, userCode, expiresIn, interval
        case verificationURI = "verificationURI"
    }
}

public struct GitHubDeviceTokenResponse: Codable, Equatable, Sendable {
    public let status: String
    public let accessToken: String?
    public let tokenType: String?
    public let scope: String?
    public let error: String?
    public let message: String?
    public let interval: UInt64?
}

public struct GitHubMergeResult: Codable, Equatable, Sendable {
    public let merged: Bool
    public let message: String
    public let sha: String?
}

public enum GitHubRequestHost: String, Codable, Sendable {
    case api
    case web
}

public struct GitHubRequestPlan: Codable, Equatable, Sendable {
    public let host: GitHubRequestHost
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: String?
    public let requiresAuthentication: Bool

    public init(
        host: GitHubRequestHost,
        method: String,
        path: String,
        query: [String: String],
        body: String?,
        requiresAuthentication: Bool
    ) {
        self.host = host
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.requiresAuthentication = requiresAuthentication
    }
}

public struct GitHubRequest: Codable, Equatable, Sendable {
    public let operation: String
    public var repository: GitHubRepository?
    public var pullNumber: UInt64?
    public var clientID: String?
    public var deviceCode: String?
    public var title: String?
    public var body: String?
    public var head: String?
    public var base: String?
    public var draft: Bool?
    public var state: String?
    public var event: String?
    public var mergeMethod: String?
    public var labels: [String]?
    public var assignees: [String]?

    public init(
        operation: String,
        repository: GitHubRepository? = nil,
        pullNumber: UInt64? = nil,
        clientID: String? = nil,
        deviceCode: String? = nil,
        title: String? = nil,
        body: String? = nil,
        head: String? = nil,
        base: String? = nil,
        draft: Bool? = nil,
        state: String? = nil,
        event: String? = nil,
        mergeMethod: String? = nil,
        labels: [String]? = nil,
        assignees: [String]? = nil
    ) {
        self.operation = operation
        self.repository = repository
        self.pullNumber = pullNumber
        self.clientID = clientID
        self.deviceCode = deviceCode
        self.title = title
        self.body = body
        self.head = head
        self.base = base
        self.draft = draft
        self.state = state
        self.event = event
        self.mergeMethod = mergeMethod
        self.labels = labels
        self.assignees = assignees
    }

    private enum CodingKeys: String, CodingKey {
        case operation, repository, pullNumber, deviceCode, title, body, head, base
        case draft, state, event, mergeMethod, labels, assignees
        case clientID = "clientId"
    }
}

public enum GitHubNormalizedResponse: Sendable {
    case deviceAuthorization(GitHubDeviceAuthorization)
    case deviceToken(GitHubDeviceTokenResponse)
    case user(GitHubUser)
    case pullRequests([GitHubPullRequest])
    case pullRequest(GitHubPullRequest)
    case files([GitHubPullRequestFile])
    case comments([GitHubComment])
    case comment(GitHubComment)
    case review
    case metadata
    case merge(GitHubMergeResult)
}
