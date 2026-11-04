import Foundation
import LitheCoreContracts

extension RustCoreBridge: AICommitPlanning {
    func planCommit(input: CommitMessageInput, settings: CommitMessageAISettings, provider: AIProviderProfile) throws -> AICommitRequestPlan {
        struct Provider: Encodable {
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
        }
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
        struct Payload: Encodable { let provider: Provider; let options: Options; let files: [File] }
        struct Result: Decodable { let url: String; let body: ToolingJSONValue }
        let lengths = input.files.map { $0.diff.unicodeScalars.count }
        do {
            let budget: Budgets = try executeResult(command: "ai.commitInputBudget", payload: BudgetPayload(
                maximumDiffCharacters: settings.maximumDiffCharacters, fileLengths: lengths
            )).get()
            guard budget.files.count == input.files.count,
                  zip(budget.files, lengths).allSatisfy({ allocation, length in
                      allocation.characters >= 0 && allocation.characters <= length &&
                      allocation.truncated == (allocation.characters < length)
                  }) else { throw CommitMessageGenerationError.invalidResponse }
            let files = zip(zip(input.files, lengths), budget.files).map { pair, allocation in
                File(path: pair.0.path, changeKind: pair.0.changeKind.rawValue,
                    diff: String(pair.0.diff.unicodeScalars.prefix(allocation.characters)), originalCharacters: pair.1)
            }
            let payload = Payload(
                provider: Provider(id: provider.id.uuidString, name: provider.name, endpoint: provider.endpoint,
                    model: provider.model, apiProtocol: provider.apiProtocol.rawValue,
                    chatTokenLimitField: provider.chatTokenLimitField.rawValue, authentication: provider.authentication.rawValue, source: provider.credentialSource.rawValue,
                    requiresApiKey: provider.requiresAPIKey, allowsInsecureHttp: provider.allowsInsecureHTTP),
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
