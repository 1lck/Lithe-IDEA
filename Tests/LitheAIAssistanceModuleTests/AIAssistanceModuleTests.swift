import Foundation
import LitheAIAssistanceModule
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing

@MainActor
struct AIAssistanceModuleTests {
    @Test
    func disabledModuleDoesNotConstructFactoryOrTransport() async throws {
        let recorder = FactoryRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(ModuleFactory(manifest: AIAssistanceModule.moduleManifest, contributions: AIAssistanceModule.moduleContributions) {
            recorder.moduleFactoryCalls += 1
            return AIAssistanceModule(
                transportFactory: {
                    recorder.transportFactoryCalls += 1
                    return TestTransport()
                },
                credentialResolver: TestCredentialResolver()
            )
        })

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.aiAssistance)) {
            _ = try await runtime.activateCapability(.aiCommitMessage)
        }
        #expect(recorder.moduleFactoryCalls == 0)
        #expect(recorder.transportFactoryCalls == 0)
        #expect(try !runtime.snapshot(for: .aiAssistance).isInstantiated)
    }

    @Test
    func sleepReleasesCapabilityAndWakeReconstructsServiceGraph() async throws {
        let recorder = FactoryRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(ModuleFactory(manifest: AIAssistanceModule.moduleManifest, contributions: AIAssistanceModule.moduleContributions) {
            recorder.moduleFactoryCalls += 1
            return AIAssistanceModule(
                transportFactory: {
                    recorder.transportFactoryCalls += 1
                    return TestTransport()
                },
                credentialResolver: TestCredentialResolver()
            )
        })
        try await runtime.setEnabled(true, for: .aiAssistance)

        var first: AIAssistanceCapability? = try #require(
            try await runtime.activateCapability(.aiCommitMessage) as? AIAssistanceCapability
        )
        weak var releasedCapability = first
        #expect(recorder.moduleFactoryCalls == 1)
        #expect(recorder.transportFactoryCalls == 1)
        first = nil

        try await runtime.sleep(.aiAssistance)
        #expect(releasedCapability == nil)
        #expect(runtime.capability(.aiCommitMessage) == nil)
        #expect(runtime.capability(.aiPullRequestDescription) == nil)
        #expect(try runtime.snapshot(for: .aiAssistance).activity.activeResourceCount == 0)

        let second = try #require(
            try await runtime.activateCapability(.aiCommitMessage) as? AIAssistanceCapability
        )
        #expect(second !== releasedCapability)
        #expect(runtime.capability(.aiPullRequestDescription) === second)
        #expect(recorder.moduleFactoryCalls == 2)
        #expect(recorder.transportFactoryCalls == 2)
    }
}

@MainActor
private final class FactoryRecorder {
    var moduleFactoryCalls = 0
    var transportFactoryCalls = 0
}

private struct TestCredentialResolver: AIProviderCredentialResolver {
    func readAPIKey(for provider: AIProviderProfile) -> String? { nil }
}

private struct TestTransport: AIHTTPTransport {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        AIHTTPResponse(statusCode: 200, body: Data(#"{"output_text":"test"}"#.utf8))
    }
}
