import Foundation
import LitheCoreContracts

extension RustCoreBridge: AICommitPlanning {
    func planCommit(input: CommitMessageInput, settings: CommitMessageAISettings, provider: AIProviderProfile) throws -> AICommitRequestPlan {
        struct Options: Encodable {
            let language: String
            let format: String
            let customInstructions: String
            let includeBody: Bool
            let subjectMaximumLength: Int
            let maximumDiffCharacters: Int
            let reasoningEffort: String
        }
        struct File: Encodable { let path: String; let changeKind: String; let diff: String; let originalCharacters: Int }
        struct BudgetPayload: Encodable { let maximumDiffCharacters: Int; let fileLengths: [Int] }
        struct Budget: Decodable { let characters: Int; let truncated: Bool }
        struct Budgets: Decodable { let files: [Budget] }
        struct Payload: Encodable { let provider: CoreAIProvider; let options: Options; let files: [File] }
        struct Result: Decodable { let url: String; let body: ToolingJSONValue }
        let lengths = input.files.map(\.originalCharacters)
        do {
            let budget: Budgets = try executeResult(command: "ai.commitInputBudget", payload: BudgetPayload(
                maximumDiffCharacters: settings.maximumDiffCharacters, fileLengths: lengths
            )).get()
            guard budget.files.count == input.files.count,
                  zip(zip(budget.files, lengths), input.files).allSatisfy({ pair, file in
                      let (allocation, length) = pair
                      return allocation.characters >= 0 && allocation.characters <= length &&
                          allocation.characters <= file.diff.unicodeScalars.count &&
                          allocation.truncated == (allocation.characters < length)
                  }) else { throw CommitMessageGenerationError.invalidResponse }
            let files = zip(zip(input.files, lengths), budget.files).map { pair, allocation in
                File(path: pair.0.path, changeKind: pair.0.changeKind.rawValue,
                    diff: String(pair.0.diff.unicodeScalars.prefix(allocation.characters)), originalCharacters: pair.1)
            }
            let payload = Payload(
                provider: CoreAIProvider(provider),
                options: Options(language: settings.language.rawValue, format: settings.format.rawValue,
                    customInstructions: settings.customInstructions, includeBody: settings.includeBody,
                    subjectMaximumLength: settings.subjectMaximumLength, maximumDiffCharacters: settings.maximumDiffCharacters,
                    reasoningEffort: settings.reasoningEffort.rawValue),
                files: files
            )
            let result: Result = try executeResult(command: "ai.planCommit", payload: payload).get()
            guard let url = URL(string: result.url) else { throw CommitMessageGenerationError.invalidProvider }
            return try AICommitRequestPlan(url: url, body: JSONEncoder().encode(result.body))
        } catch let error as CoreCallError {
            throw Self.commitGenerationError(error.message)
        }
    }

    func decodeCommitResponse(protocolName: CommitMessageAPIProtocol, response: Data, includeBody: Bool) throws -> String {
        struct Payload: Encodable { let `protocol`: String; let response: ToolingJSONValue; let includeBody: Bool }
        struct Result: Decodable { let message: String }
        guard response.count <= 2 * 1024 * 1024,
              let json = try? JSONDecoder().decode(ToolingJSONValue.self, from: response) else {
            throw CommitMessageGenerationError.invalidResponse
        }
        do {
            let result: Result = try executeResult(command: "ai.decodeCommitMessage", payload: Payload(
                protocol: protocolName.rawValue, response: json, includeBody: includeBody
            )).get()
            return result.message
        } catch let error as CoreCallError {
            throw Self.commitGenerationError(error.message)
        }
    }

    func planPullRequest(
        input: PullRequestDescriptionInput,
        settings: CommitMessageAISettings,
        provider: AIProviderProfile
    ) throws -> AICommitRequestPlan {
        struct Options: Encodable {
            let language: String
            let format: String
            let customTemplate: String
            let maximumDiffCharacters: Int
            let reasoningEffort: String
        }
        struct File: Encodable { let path: String; let changeKind: String; let diff: String }
        struct Comparison: Encodable {
            let repository: String
            let base: String
            let head: String
            let commitMessages: [String]
            let files: [File]
        }
        struct Payload: Encodable { let provider: CoreAIProvider; let options: Options; let comparison: Comparison }
        struct Result: Decodable { let url: String; let body: ToolingJSONValue }
        let payload = Payload(
            provider: CoreAIProvider(provider),
            options: Options(
                language: settings.language.rawValue,
                format: settings.pullRequestFormat.rawValue,
                customTemplate: settings.pullRequestCustomTemplate,
                maximumDiffCharacters: settings.maximumDiffCharacters,
                reasoningEffort: settings.reasoningEffort.rawValue
            ),
            comparison: Comparison(
                repository: input.repository,
                base: input.base,
                head: input.head,
                commitMessages: input.commitMessages,
                files: input.files.map { File(path: $0.path, changeKind: $0.changeKind.rawValue, diff: $0.patch) }
            )
        )
        do {
            let result: Result = try executeResult(command: "ai.pullRequest.plan", payload: payload).get()
            guard let url = URL(string: result.url) else { throw CommitMessageGenerationError.invalidProvider }
            return try AICommitRequestPlan(url: url, body: JSONEncoder().encode(result.body))
        } catch let error as CoreCallError {
            throw Self.pullRequestGenerationError(error.message)
        }
    }

    func decodePullRequestResponse(
        protocolName: CommitMessageAPIProtocol,
        response: Data
    ) throws -> PullRequestDescriptionOutput {
        struct Payload: Encodable { let `protocol`: String; let response: ToolingJSONValue }
        guard response.count <= 2 * 1024 * 1024,
              let json = try? JSONDecoder().decode(ToolingJSONValue.self, from: response) else {
            throw PullRequestDescriptionGenerationError.invalidResponse
        }
        do {
            return try executeResult(command: "ai.pullRequest.decode", payload: Payload(
                protocol: protocolName.rawValue, response: json
            )).get()
        } catch let error as CoreCallError {
            throw Self.pullRequestGenerationError(error.message)
        }
    }

    private static func pullRequestGenerationError(_ code: String) -> any Error {
        switch code {
        case "AI_PULL_REQUEST_EMPTY_COMPARISON": PullRequestDescriptionGenerationError.emptyComparison
        case "AI_PULL_REQUEST_EMPTY_RESPONSE": PullRequestDescriptionGenerationError.emptyResponse
        case "AI_PULL_REQUEST_INVALID_RESPONSE": PullRequestDescriptionGenerationError.invalidResponse
        case "AI_COMMIT_TOO_MANY_FILES": CommitMessageGenerationError.tooManyFiles
        default: commitGenerationError(code)
        }
    }

    private static func commitGenerationError(_ code: String) -> CommitMessageGenerationError {
        switch code {
        case "AI_COMMIT_INVALID_PROVIDER": .invalidProvider
        case "AI_COMMIT_INVALID_OPTIONS": .invalidOptions
        case "AI_COMMIT_INSECURE_ENDPOINT": .insecureEndpoint
        case "AI_COMMIT_EMPTY_DIFF": .emptyDiff
        case "AI_COMMIT_SENSITIVE_FILE": .sensitiveFileExcluded
        case "AI_COMMIT_EMPTY_RESPONSE": .emptyResponse
        case "AI_COMMIT_OUTPUT_LIMIT": .outputLimit
        default: .invalidResponse
        }
    }
}

/// Credential-free provider profile in the shared Core contract.
private struct CoreAIProvider: Encodable {
    let id: String
    let name: String
    let endpoint: String
    let model: String
    let apiProtocol: String
    let chatTokenLimitField: String
    let authentication: String
    let source: String
    let requiresApiKey: Bool
    let allowsInsecureHttp: Bool

    init(_ provider: AIProviderProfile) {
        id = provider.id.uuidString
        name = provider.name
        endpoint = provider.endpoint
        model = provider.model
        apiProtocol = provider.apiProtocol.rawValue
        chatTokenLimitField = provider.chatTokenLimitField.rawValue
        authentication = provider.authentication.rawValue
        source = provider.credentialSource.rawValue
        requiresApiKey = provider.requiresAPIKey
        allowsInsecureHttp = provider.allowsInsecureHTTP
    }
}
