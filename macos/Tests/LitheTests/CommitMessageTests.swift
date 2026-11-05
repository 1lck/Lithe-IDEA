import AppKit
import Foundation
import LitheAIAssistanceModule
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Commit message generation")
struct CommitMessageTests {
    @Test
    func switchingNewProviderToAnthropicRequiresModelBeforeEncodingRequest() async throws {
        var settings = CommitMessageAISettings.default
        let provider = settings.addProvider()
        settings.updateActiveProvider {
            $0.endpoint = "https://example.test/v1"
            $0.apiProtocol = .anthropicMessages
        }
        let transport = MockAIHTTPTransport(response: AIHTTPResponse(statusCode: 200,
            body: Data(#"{"content":[{"type":"text","text":"feat: update checker"}]}"#.utf8)))
        let service = CommitMessageGenerationService(core: RustCoreBridge(), transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(
                values: [provider.apiKeyIdentifier: "fixture-secret"]))
        let input = CommitMessageInput(path: "Sources/UpdateChecker.swift", changeKind: .modified,
            diff: "@@ -1,1 +1,2 @@\n-old\n+new")

        do {
            _ = try await service.generate(input: input, settings: settings)
            Issue.record("A new Anthropic provider must require an explicit model before sending")
        } catch CommitMessageGenerationError.invalidProvider {
            // Missing model must fail locally before transport is called.
        }
        #expect(await transport.lastRequest == nil)

        settings.updateActiveProvider { $0.model = "fixture-claude-model" }
        #expect(try await service.generate(input: input, settings: settings) == "feat: update checker")
        let request = try #require(await transport.lastRequest)
        #expect(request.url.absoluteString == "https://example.test/v1/messages")
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["model"] as? String == "fixture-claude-model")
    }

    @Test
    func anthropicGenerationUsesNativeMessagesRequestAndHeaders() async throws {
        let profile = AIProviderProfile(
            name: "Claude",
            endpoint: "https://api.anthropic.com",
            model: "claude-sonnet-custom",
            apiProtocol: .anthropicMessages,
            apiKeyIdentifier: "claude-key",
            requiresAPIKey: true,
            credentialSource: .local
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                body: Data(#"{"content":[{"type":"text","text":"feat: update checker"}]}"#.utf8)
            )
        )
        let credentialResolver = InMemoryAIProviderCredentialResolver(
            values: ["claude-key": "claude-secret"]
        )
        let service = CommitMessageGenerationService(
            core: RustCoreBridge(),
            transport: transport,
            credentialResolver: credentialResolver
        )

        let input = CommitMessageInput(
            path: "Sources/UpdateChecker.swift",
            changeKind: .modified,
            diff: "@@ -1,1 +1,2 @@\n-old\n+new"
        )
        let message = try await service.generate(input: input, settings: settings)

        #expect(message == "feat: update checker")
        let request = await transport.lastRequest
        #expect(request?.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request?.headers["x-api-key"] == "claude-secret")
        #expect(request?.headers["Authorization"] == nil)
        #expect(request?.headers["anthropic-version"] == "2023-06-01")

        let body = try #require(request?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-custom")
        #expect(json["max_tokens"] as? Int == 4_096)
        #expect(json["system"] as? String != nil)
        #expect(json["messages"] as? [[String: Any]] != nil)
    }

    @Test
    func httpProviderRequiresExplicitOptIn() async throws {
        let profile = AIProviderProfile(
            name: "HTTP proxy",
            endpoint: "http://127.0.0.1:8888",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            apiKeyIdentifier: "http-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"feat: update checker"}}]}"#.utf8))
        )
        let service = CommitMessageGenerationService(
            core: RustCoreBridge(),
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(values: ["http-key": "secret"])
        )

        do {
            _ = try await service.generate(input: testCommitMessageInput, settings: settings)
            Issue.record("HTTP generation should require explicit opt-in")
        } catch let error as CommitMessageGenerationError {
            guard case .insecureEndpoint = error else {
                Issue.record("HTTP generation returned the wrong error")
                return
            }
        }
        #expect(await transport.lastRequest == nil)
    }

    @Test
    func httpProviderCarriesExplicitOptInToTransport() async throws {
        let profile = AIProviderProfile(
            name: "HTTP proxy",
            endpoint: "http://127.0.0.1:8888",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            allowsInsecureHTTP: true,
            apiKeyIdentifier: "http-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"feat: update checker"}}]}"#.utf8))
        )
        let service = CommitMessageGenerationService(
            core: RustCoreBridge(),
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(values: ["http-key": "secret"])
        )

        #expect(try await service.generate(input: testCommitMessageInput, settings: settings) == "feat: update checker")
        #expect(await transport.lastRequest?.allowsInsecureHTTP == true)
    }

    @Test
    func responsesGenerationUsesConfiguredEndpointModelReasoningAndKey() async throws {
        let profile = AIProviderProfile(
            name: "Test Codex",
            endpoint: "https://example.test/codex/v1",
            model: "fast-model",
            apiProtocol: .responses,
            apiKeyIdentifier: "test-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id
        settings.reasoningEffort = .low

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                body: Data(#"{"output_text":"feat: update checker"}"#.utf8)
            )
        )
        let credentialResolver = InMemoryAIProviderCredentialResolver(
            values: ["test-key": "test-secret"]
        )
        let service = CommitMessageGenerationService(
            core: RustCoreBridge(),
            transport: transport,
            credentialResolver: credentialResolver
        )

        let input = CommitMessageInput(
            path: "Sources/UpdateChecker.swift",
            changeKind: .modified,
            diff: "@@ -1,1 +1,2 @@\n-old\n+new"
        )
        let message = try await service.generate(input: input, settings: settings)

        #expect(message == "feat: update checker")
        let request = await transport.lastRequest
        #expect(request?.url.absoluteString == "https://example.test/codex/v1/responses")
        #expect(request?.headers["Authorization"] == "Bearer test-secret")

        let body = try #require(request?.body)
        #expect(!String(decoding: body, as: UTF8.self).contains("test-secret"))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "fast-model")
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
        #expect(json["store"] as? Bool == false)
    }

    @Test
    func generationSendsTheCompleteStagedFileSetWithBoundaries() async throws {
        let profile = AIProviderProfile(
            name: "Test provider",
            endpoint: "https://example.test/api",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            apiKeyIdentifier: "test-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                body: Data(#"{"choices":[{"message":{"content":"docs: update project documentation"}}]}"#.utf8)
            )
        )
        let service = CommitMessageGenerationService(
            core: RustCoreBridge(),
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(
                values: ["test-key": "test-secret"]
            )
        )
        let input = CommitMessageInput(files: [
            CommitMessageFileInput(
                path: "README.md",
                changeKind: .modified,
                diff: "@@ -1 +1 @@\n-old docs\n+new docs"
            ),
            CommitMessageFileInput(
                path: "README.zh-CN.md",
                changeKind: .modified,
                diff: "@@ -1 +1 @@\n-旧文档\n+新文档"
            )
        ])

        _ = try await service.generate(input: input, settings: settings)

        let body = try #require(await transport.lastRequest?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userPrompt = try #require(messages[1]["content"] as? String)
        #expect(userPrompt.contains("path: \"README.md\""))
        #expect(userPrompt.contains("path: \"README.zh-CN.md\""))
        #expect(userPrompt.components(separatedBy: "--- BEGIN FILE ---").count == 3)
        #expect(userPrompt.components(separatedBy: "--- END FILE ---").count == 3)

        let systemPrompt = try #require(messages[0]["content"] as? String)
        #expect(systemPrompt.contains("complete selected changes"))
        #expect(systemPrompt.contains("do not infer behavior from filenames"))
    }

    @Test
    func sharedCommitFixtureMatchesActualCoreBridgeForEveryProtocol() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/ai/commit-generation-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try #require(fixture["files"] as? [[String: String]])
        let input = CommitMessageInput(files: try files.map { file in
            let kind = try #require(file["changeKind"])
            return CommitMessageFileInput(path: try #require(file["path"]),
                changeKind: try #require(CommitMessageChangeKind(rawValue: kind)),
                diff: try #require(file["diff"]))
        })
        let cases = try #require(fixture["responses"] as? [[String: Any]])
        let expected = try #require(fixture["expectedMessage"] as? String)
        var settings = CommitMessageAISettings.default
        settings.includeBody = false
        settings.language = .simplifiedChinese
        let core = RustCoreBridge()
        for item in cases {
            let protocolValue = try #require(item["protocol"] as? String)
            let protocolName = try #require(CommitMessageAPIProtocol(rawValue: protocolValue))
            let provider = AIProviderProfile(name: "Example", endpoint: "https://api.example.com/v1",
                model: "example-model", apiProtocol: protocolName, requiresAPIKey: false)
            let plan = try core.planCommit(input: input, settings: settings, provider: provider)
            let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
            let tokenField = try #require(item["tokenField"] as? String)
            #expect(body[tokenField] as? Int == 4_096)
            let response = try JSONSerialization.data(withJSONObject: try #require(item["body"]))
            #expect(try core.decodeCommitResponse(protocolName: protocolName, response: response, includeBody: false) == expected)
        }
    }

    @Test
    func legacyChatCompletionsProfilesKeepTheirOriginalTokenField() throws {
        let original = AIProviderProfile(name: "Legacy", endpoint: "https://example.test/v1", model: "fixture",
            apiProtocol: .chatCompletions, requiresAPIKey: false)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "chatTokenLimitField")
        let legacy = try JSONDecoder().decode(AIProviderProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.chatTokenLimitField == .maxTokens)
        #expect(original.chatTokenLimitField == .maxCompletionTokens)
        let roundTrip = try JSONDecoder().decode(AIProviderProfile.self, from: JSONEncoder().encode(legacy))
        #expect(roundTrip.chatTokenLimitField == .maxTokens)
        let plan = try RustCoreBridge().planCommit(input: testCommitMessageInput, settings: .default, provider: legacy)
        let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 4_096)
        #expect(body["max_completion_tokens"] == nil)
        let modern = try RustCoreBridge().planCommit(input: testCommitMessageInput, settings: .default, provider: original)
        let modernBody = try #require(JSONSerialization.jsonObject(with: modern.body) as? [String: Any])
        #expect(modernBody["max_completion_tokens"] as? Int == 4_096)
        #expect(modernBody["max_tokens"] == nil)
    }

    @Test
    func largeDiffsCrossTheCoreBoundaryOnlyWithinTheSharedBudget() throws {
        let provider = AIProviderProfile(name: "Example", endpoint: "https://example.test/v1", model: "fixture",
            apiProtocol: .responses, requiresAPIKey: false)
        var settings = CommitMessageAISettings.default
        settings.maximumDiffCharacters = 8_000
        let input = CommitMessageInput(files: [
            CommitMessageFileInput(path: "large.txt", changeKind: .modified, diff: String(repeating: "😀", count: 250_000)),
            CommitMessageFileInput(path: "small.txt", changeKind: .modified, diff: "+small")
        ])
        let plan = try RustCoreBridge().planCommit(input: input, settings: settings, provider: provider)
        #expect(plan.body.count < 50_000)
        let body = String(decoding: plan.body, as: UTF8.self)
        #expect(body.contains("Diff truncated"))
        #expect(body.contains("small.txt"))
        #expect(body.contains("+small"))
    }

    @Test
    func coreBoundedCommitEvidenceKeepsItsOriginalTruncationWarning() throws {
        let provider = AIProviderProfile(name: "Example", endpoint: "https://example.test/v1", model: "fixture",
            apiProtocol: .responses, requiresAPIKey: false)
        var settings = CommitMessageAISettings.default
        settings.maximumDiffCharacters = 8_000
        let input = CommitMessageInput(files: [CommitMessageFileInput(path: "large.txt", changeKind: .modified,
            diff: String(repeating: "界", count: 8_000), originalCharacters: 12_000)])
        let plan = try RustCoreBridge().planCommit(input: input, settings: settings, provider: provider)
        #expect(String(decoding: plan.body, as: UTF8.self).contains("Diff truncated"))
    }

    @Test
    func cancelledCommitGenerationDoesNotSendAnHTTPRequest() async throws {
        let profile = AIProviderProfile(name: "Example", endpoint: "https://example.test/v1", model: "fixture",
            apiProtocol: .responses, requiresAPIKey: false)
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id
        let transport = MockAIHTTPTransport(response: AIHTTPResponse(statusCode: 200, body: Data(#"{"output_text":"unused"}"#.utf8)))
        let service = CommitMessageGenerationService(core: RustCoreBridge(), transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(values: [:]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.generate(input: testCommitMessageInput, settings: settings)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.lastRequest == nil)
    }

    @Test
    func coreRejectsSensitiveFilesBeforeTransport() async throws {
        let profile = AIProviderProfile(name: "Example", endpoint: "https://example.test/v1", model: "fixture",
            apiProtocol: .responses, requiresAPIKey: false)
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id
        let transport = MockAIHTTPTransport(response: AIHTTPResponse(statusCode: 200, body: Data(#"{"output_text":"unused"}"#.utf8)))
        let service = CommitMessageGenerationService(core: RustCoreBridge(), transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(values: [:]))
        let input = CommitMessageInput(path: "config/auth.json", changeKind: .modified, diff: "+sensitive")
        do {
            _ = try await service.generate(input: input, settings: settings)
            Issue.record("Sensitive credentials must not be sent")
        } catch CommitMessageGenerationError.sensitiveFileExcluded { }
        #expect(await transport.lastRequest == nil)
    }

    @Test
    func coreRejectsTruncatedOutputAndKeepsOnlySubjectWhenRequested() async throws {
        let core = RustCoreBridge()
        let partial = Data(#"{"output_text":"partial","incomplete_details":{"reason":"max_output_tokens"}}"#.utf8)
        do {
            _ = try core.decodeCommitResponse(protocolName: .responses, response: partial, includeBody: false)
            Issue.record("A truncated provider response must not become a commit draft")
        } catch CommitMessageGenerationError.outputLimit { }
        let complete = Data(#"{"output_text":"fix: summary\n\nbody"}"#.utf8)
        #expect(try core.decodeCommitResponse(protocolName: .responses, response: complete, includeBody: false) == "fix: summary")
    }

    @Test
    func pullRequestGenerationReturnsStructuredGroundedContent() async throws {
        let profile = AIProviderProfile(
            name: "Test provider",
            endpoint: "https://example.test/api",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            apiKeyIdentifier: "test-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id
        settings.pullRequestFormat = .custom
        settings.pullRequestCustomTemplate = "## Summary\n\n{summary}\n\n## Testing\n\n{testing}"
        let generatedData = try JSONSerialization.data(withJSONObject: [
            "title": "Add AI PR descriptions",
            "description": "## Summary\n\nAdds grounded PR descriptions."
        ])
        let generated = String(decoding: generatedData, as: UTF8.self)
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": generated]]]
        ])
        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(statusCode: 200, body: responseBody)
        )
        let service = CommitMessageGenerationService(
            core: RustCoreBridge(),
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(
                values: ["test-key": "test-secret"]
            )
        )
        let input = PullRequestDescriptionInput(
            repository: "example/lithe",
            base: "main",
            head: "feature/ai-pr",
            commitMessages: ["Add generation"],
            files: [PullRequestDescriptionFileInput(
                path: "Sources/PullRequest.swift",
                changeKind: .modified,
                patch: "@@ -1 +1 @@\n-old\n+new"
            )]
        )

        let output = try await service.generatePullRequestDescription(
            input: input,
            settings: settings
        )

        #expect(output.title == "Add AI PR descriptions")
        #expect(output.description.contains("Adds grounded PR descriptions"))
        let body = try #require(await transport.lastRequest?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let systemPrompt = try #require(messages[0]["content"] as? String)
        let userPrompt = try #require(messages[1]["content"] as? String)
        #expect(systemPrompt.contains("Preserve this Markdown template"))
        #expect(systemPrompt.contains("never claim tests passed"))
        #expect(userPrompt.contains(#"Base branch: "main""#))
        #expect(userPrompt.contains(#"Compare branch: "feature/ai-pr""#))
        #expect(userPrompt.contains(#"path: "Sources/PullRequest.swift""#))
        // Reasoning shares the output budget, so PR descriptions use the commit budget.
        #expect(json["max_completion_tokens"] as? Int == 4_096)
    }

    @Test
    func sharedPullRequestFixtureMatchesActualCoreBridge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "shared/fixtures/ai/pull-request-description-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let comparison = try #require(fixture["comparison"] as? [String: Any])
        let fileObjects = try #require(comparison["files"] as? [[String: String]])
        let files = try fileObjects.map { file in
            let kind = try #require(file["changeKind"])
            return PullRequestDescriptionFileInput(
                path: try #require(file["path"]),
                changeKind: try #require(CommitMessageChangeKind(rawValue: kind)),
                patch: try #require(file["diff"])
            )
        }
        let input = PullRequestDescriptionInput(
            repository: try #require(comparison["repository"] as? String),
            base: try #require(comparison["base"] as? String),
            head: try #require(comparison["head"] as? String),
            commitMessages: try #require(comparison["commitMessages"] as? [String]),
            files: files
        )
        let options = try #require(fixture["options"] as? [String: Any])
        var settings = CommitMessageAISettings.default
        settings.pullRequestFormat = .custom
        settings.pullRequestCustomTemplate = try #require(options["customTemplate"] as? String)
        let expected = try #require(fixture["expectedDescription"] as? [String: String])
        let core = RustCoreBridge()
        for item in try #require(fixture["responses"] as? [[String: Any]]) {
            let protocolText = try #require(item["protocol"] as? String)
            let protocolName = try #require(CommitMessageAPIProtocol(rawValue: protocolText))
            let provider = AIProviderProfile(name: "Example", endpoint: "https://api.example.com/v1",
                model: "example-model", apiProtocol: protocolName, requiresAPIKey: false)
            let plan = try core.planPullRequest(input: input, settings: settings, provider: provider)
            let body = try #require(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
            #expect(body[try #require(item["tokenField"] as? String)] as? Int == 4_096)
            #expect(!String(decoding: plan.body, as: UTF8.self).contains("Assets/logo.png"))
            let response = try JSONSerialization.data(withJSONObject: try #require(item["body"]))
            let output = try core.decodePullRequestResponse(protocolName: protocolName, response: response)
            #expect(output == PullRequestDescriptionOutput(
                title: try #require(expected["title"]), description: try #require(expected["description"])))
        }
        for item in try #require(fixture["decodeRejections"] as? [[String: Any]]) {
            let protocolText = try #require(item["protocol"] as? String)
            let protocolName = try #require(CommitMessageAPIProtocol(rawValue: protocolText))
            let response = try JSONSerialization.data(withJSONObject: try #require(item["body"]))
            #expect(throws: (any Error).self) {
                try core.decodePullRequestResponse(protocolName: protocolName, response: response)
            }
        }
        let sensitive = PullRequestDescriptionInput(repository: "example/lithe", base: "main", head: "topic",
            commitMessages: [], files: [PullRequestDescriptionFileInput(
                path: "config/credentials.json", changeKind: .modified, patch: "+x")])
        let provider = AIProviderProfile(name: "Example", endpoint: "https://api.example.com/v1",
            model: "example-model", apiProtocol: .responses, requiresAPIKey: false)
        #expect(throws: CommitMessageGenerationError.self) {
            try core.planPullRequest(input: sensitive, settings: settings, provider: provider)
        }
    }
}

private let testCommitMessageInput = CommitMessageInput(
    path: "Sources/UpdateChecker.swift",
    changeKind: .modified,
    diff: "@@ -1,1 +1,2 @@\n-old\n+new"
)

@Suite("Commit message settings")
@MainActor
struct CommitMessageSettingsTests {
    @Test
    func outputTokenFieldPersistsWithItsProvider() throws {
        let store = InMemoryKeyValueStore()
        let settings = AppSettings(store: store)
        let id = settings.addAIProvider()
        settings.updateAIProvider(id) { provider in
            provider.apiProtocol = .chatCompletions
            provider.chatTokenLimitField = .maxTokens
        }
        let reloaded = AppSettings(store: store)
        #expect(reloaded.commitMessageAI.providers.first { $0.id == id }?.chatTokenLimitField == .maxTokens)
    }

    @Test
    func linkedAgentModelsRefreshWithoutChangingOtherProviderSettings() throws {
        let store = InMemoryKeyValueStore()
        let settings = AppSettings(store: store)
        let codex = AIProviderProfile(name: "Codex", endpoint: "https://old.example.test/v1", model: "obsolete-model",
            apiProtocol: .responses, apiKeyIdentifier: "codex-key", credentialSource: .codex)
        let claude = AIProviderProfile(name: "Claude", endpoint: "https://claude.example.test", model: "old-claude",
            apiProtocol: .anthropicMessages, apiKeyIdentifier: "claude-key", credentialSource: .claude)
        let manual = AIProviderProfile(name: "Manual", endpoint: "https://manual.example.test/v1", model: "manual-model",
            apiProtocol: .responses, apiKeyIdentifier: "manual-key", credentialSource: .local)
        let unlinked = AIProviderProfile(name: "Unlinked", endpoint: codex.endpoint, model: codex.model,
            apiProtocol: .responses, apiKeyIdentifier: "unlinked-key", credentialSource: .codex)
        var initial = settings.commitMessageAI
        initial.providers = [codex, claude, manual, unlinked]
        initial.activeProviderID = manual.id
        settings.commitMessageAI = initial
        settings.setAgentProvider(codex.id, for: "codex-acp", name: "Codex")
        settings.setAgentProvider(claude.id, for: "claude-acp", name: "Claude")
        settings.setAgentProvider(manual.id, for: "custom", name: "Manual")
        let snapshots: [AIConfigurationSnapshot] = [
            .init(source: .codex, providerName: "Current", endpoint: "https://new.example.test/v1", model: "current-codex",
                apiProtocol: .responses, reasoningEffort: nil, requiresAPIKey: true, apiKey: "test-secret"),
            .init(source: .claude, providerName: "Current", endpoint: "https://new.example.test", model: "current-claude",
                apiProtocol: .anthropicMessages, reasoningEffort: nil, requiresAPIKey: true, apiKey: "test-secret")
        ]
        settings.refreshAgentModels(from: snapshots.map { .init(source: $0.source, model: $0.model) })
        var expected = initial
        expected.providers[0].model = "current-codex"
        expected.providers[1].model = "current-claude"
        #expect(settings.commitMessageAI == expected)
        #expect(settings.agentProvider(for: "codex-acp")?.model == "current-codex")
        #expect(AppSettings(store: store).commitMessageAI == expected, "the next connection must not restore the stale import")
        let saved = try #require(store.data(forKey: "settings.commitMessageAI"))
        #expect(!String(decoding: saved, as: UTF8.self).contains("test-secret"))
    }

    @Test
    func agentModelRefreshKeepsMissingSourcesAndSupportsAnEmptyCliDefault() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        let provider = AIProviderProfile(name: "Codex", endpoint: "https://example.test/v1", model: "saved-model",
            apiProtocol: .responses, apiKeyIdentifier: "codex-key", credentialSource: .codex)
        var initial = settings.commitMessageAI
        initial.providers = [provider]
        initial.activeProviderID = provider.id
        settings.commitMessageAI = initial
        settings.setAgentProvider(provider.id, for: "codex-acp", name: "Codex")
        settings.refreshAgentModels(from: [])
        #expect(settings.commitMessageAI == initial, "missing configuration must not invent a model")
        settings.refreshAgentModels(from: [.init(source: .codex, model: "")])
        #expect(settings.agentProvider(for: "codex-acp")?.model == "", "an empty local model delegates to the agent")
    }

    @Test
    func legacyAISettingsGainPullRequestDefaults() throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CommitMessageAISettings.default)
            ) as? [String: Any]
        )
        object["pullRequestFormat"] = nil
        object["pullRequestCustomTemplate"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CommitMessageAISettings.self, from: data)

        #expect(decoded.pullRequestFormat == .standard)
        #expect(decoded.pullRequestCustomTemplate == CommitMessageAISettings.defaultPullRequestTemplate)
    }

    @Test
    func themeSettingsPersistAndDefaultToDarkLithe() {
        let store = InMemoryKeyValueStore()
        let initialSettings = AppSettings(store: store)
        #expect(initialSettings.colorTheme == .lithe)
        #expect(initialSettings.themePreference == .dark)
        #expect(AppThemeRuntime.shared.activeTheme == .lithe)

        initialSettings.colorTheme = .linear
        initialSettings.themePreference = .light
        #expect(AppThemeRuntime.shared.activeTheme == .linear)
        let reloadedSettings = AppSettings(store: store)
        #expect(reloadedSettings.colorTheme == .linear)
        #expect(reloadedSettings.themePreference == .light)

        reloadedSettings.restoreDefaults()
        #expect(reloadedSettings.colorTheme == .lithe)
        #expect(reloadedSettings.themePreference == .dark)
    }

    @Test
    func bundledThemeTokensMatchTheirDefinitions() {
        let cases: [(AppColorTheme, Bool, LitheTheme.ResolvedColorToken, UInt32)] = [
            (.lithe, false, .editor, 0xffffff),
            (.lithe, false, .toolHeader, 0xfbfbfc),
            (.lithe, false, .primaryText, 0x1f2329),
            (.lithe, false, .secondaryText, 0x5f6570),
            (.lithe, false, .accent, 0x3574f0),
            (.lithe, false, .divider, 0xd8dadf),
            (.codex, true, .editor, 0x111111),
            (.codex, true, .primaryText, 0xfcfcfc),
            (.codex, true, .accent, 0x0169cc),
            (.codex, true, .success, 0x00a240),
            (.codex, true, .error, 0xe02e2a),
            (.codex, true, .skill, 0xb06dff),
            (.codex, false, .editor, 0xffffff),
            (.codex, false, .primaryText, 0x0d0d0d),
            (.codex, false, .accent, 0x0169cc),
            (.codex, false, .success, 0x00a240),
            (.codex, false, .error, 0xe02e2a),
            (.codex, false, .skill, 0x751ed9),
            (.linear, true, .editor, 0x0f0f11),
            (.linear, true, .primaryText, 0xe3e4e6),
            (.linear, true, .accent, 0x606acc),
            (.linear, true, .success, 0x69c967),
            (.linear, true, .error, 0xff7e78),
            (.linear, true, .skill, 0xc2a1ff),
            (.linear, false, .editor, 0xfcfcfd),
            (.linear, false, .primaryText, 0x1b1b1b),
            (.linear, false, .accent, 0x5e6ad2),
            (.linear, false, .success, 0x52a450),
            (.linear, false, .error, 0xc94446),
            (.linear, false, .skill, 0x8160d8)
        ]

        for (theme, isDark, token, expected) in cases {
            let color = LitheTheme.nsColor(token, theme: theme, isDark: isDark)
            #expect(rgbHex(color) == expected)
        }
    }

    @Test
    func bundledToolWindowSurfacesFollowTheirThemeHierarchy() {
        for theme in AppColorTheme.allCases {
            for isDark in [false, true] {
                let editor = rgbHex(LitheTheme.nsColor(.editor, theme: theme, isDark: isDark))
                let sidebar = rgbHex(LitheTheme.nsColor(.sidebar, theme: theme, isDark: isDark))
                let toolHeader = rgbHex(LitheTheme.nsColor(.toolHeader, theme: theme, isDark: isDark))

                #expect(sidebar == editor)
                if theme == .lithe, !isDark {
                    #expect(toolHeader != editor)
                } else {
                    #expect(toolHeader == editor)
                }
            }
        }
    }

    private func rgbHex(_ color: NSColor) -> UInt32? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    @Test
    func projectOpenBehaviorPersistsAndDefaultsToAsk() {
        let store = InMemoryKeyValueStore()
        let initialSettings = AppSettings(store: store)
        #expect(initialSettings.projectOpenBehavior == .ask)

        initialSettings.projectOpenBehavior = .thisWindow
        let reloadedSettings = AppSettings(store: store)
        #expect(reloadedSettings.projectOpenBehavior == .thisWindow)
    }

    @Test
    func importingCodexStoresOnlyTheCodexSourceReferenceInSettings() throws {
        let store = InMemoryKeyValueStore()
        let settings = AppSettings(store: store)
        let snapshot = CodexConfigurationSnapshot(
            providerName: "custom",
            endpoint: "https://example.test/codex/v1",
            model: "fast-model",
            apiProtocol: .responses,
            reasoningEffort: .max,
            requiresAPIKey: true,
            apiKey: "test-secret"
        )

        let existingProvider = AIProviderProfile(
            name: "Codex",
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            chatTokenLimitField: .maxTokens,
            allowsInsecureHTTP: true,
            apiKeyIdentifier: "lithe.codex.imported.apiKey",
            credentialSource: .codex
        )
        var initialSettings = settings.commitMessageAI
        initialSettings.providers = [existingProvider]
        initialSettings.activeProviderID = existingProvider.id
        settings.commitMessageAI = initialSettings

        let provider = settings.importCodexConfiguration(snapshot)

        #expect(settings.activeCommitMessageProvider?.id == provider.id)
        #expect(settings.activeCommitMessageProvider?.model == "fast-model")
        #expect(provider.credentialSource == .codex)
        #expect(provider.allowsInsecureHTTP == true)
        #expect(provider.chatTokenLimitField == .maxTokens)
        let persisted = try #require(store.data(forKey: "settings.commitMessageAI"))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        #expect(!persistedText.contains("test-secret"))
    }

    @Test
    func codexCredentialResolverReadsTheCurrentAuthConfiguration() {
        let snapshot = CodexConfigurationSnapshot(
            providerName: "custom",
            endpoint: "https://example.test/codex/v1",
            model: "fast-model",
            apiProtocol: .responses,
            reasoningEffort: .low,
            requiresAPIKey: true,
            apiKey: "codex-secret"
        )
        let source = FixedCodexConfigurationSource(snapshot: snapshot)
        let localStore = InMemorySecureStore(values: [
            "lithe.codex.imported.apiKey": "stale-local-secret"
        ])
        let resolver = MacAIProviderCredentialResolver(
            localStore: localStore,
            codexConfigurationSource: source
        )
        let provider = AIProviderProfile(
            name: "Codex",
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            apiKeyIdentifier: "lithe.codex.imported.apiKey",
            requiresAPIKey: true,
            credentialSource: .codex
        )

        #expect(resolver.readAPIKey(for: provider) == "codex-secret")
    }

    @Test
    func localSecretStorePersistsWithoutPlaintextAndUsesPrivateFilePermissions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-secrets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = MacLocalSecretStore(fileURL: fileURL)
        try store.write("test-secret", key: "provider-key")

        #expect(store.read(key: "provider-key") == "test-secret")
        let persisted = try Data(contentsOf: fileURL)
        #expect(!String(decoding: persisted, as: UTF8.self).contains("test-secret"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)

        let reloadedStore = MacLocalSecretStore(fileURL: fileURL)
        #expect(reloadedStore.read(key: "provider-key") == "test-secret")
        try reloadedStore.delete(key: "provider-key")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}

private actor MockAIHTTPTransport: AIHTTPTransport {
    let response: AIHTTPResponse
    private(set) var lastRequest: AIHTTPRequest?

    init(response: AIHTTPResponse) {
        self.response = response
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        lastRequest = request
        return response
    }
}

private final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(key: String) -> String? {
        values[key]
    }

    func write(_ value: String, key: String) throws {
        values[key] = value
    }

    func delete(key: String) throws {
        values[key] = nil
    }
}

private final class InMemoryAIProviderCredentialResolver: AIProviderCredentialResolver, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func readAPIKey(for provider: AIProviderProfile) -> String? {
        values[provider.apiKeyIdentifier]
    }
}

private final class FixedCodexConfigurationSource: CodexConfigurationSource, @unchecked Sendable {
    let snapshot: CodexConfigurationSnapshot

    init(snapshot: CodexConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> CodexConfigurationSnapshot? {
        snapshot
    }
}

private final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
