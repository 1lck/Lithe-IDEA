import LitheApplicationKernel
import Foundation
import LitheExecutionModule
import LitheLanguageIntelligenceModule
import LitheModuleAPI

/// Owns language-intelligence capability activation and cache lookup.
@MainActor
final class LanguageIntelligenceModuleCoordinator {
    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let bind: (LanguageIntelligenceCapability) -> Void
    private let notify: @MainActor (String) -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        bind: @escaping (LanguageIntelligenceCapability) -> Void,
        notify: @escaping @MainActor (String) -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.bind = bind
        self.notify = notify
    }

    func activate() async throws -> LanguageIntelligenceCapability {
        if let cached: LanguageIntelligenceCapability = store.capability(.languageIntelligence) {
            return cached
        }
        let value = try await runtime.activateCapability(ModuleCapabilityID.languageIntelligence)
        guard let capability = value as? LanguageIntelligenceCapability else {
            throw ModuleRuntimeError.missingCapabilityDependency(
                module: .languageIntelligence, capability: .languageIntelligence
            )
        }
        bind(capability)
        return capability
    }

    func resetWorkspaceState(_ feature: LanguageToolingFeatureModel) {
        feature.resetWorkspaceState()
    }

    func stopAllLanguageServers(_ sessions: LanguageToolingSessionManager?) {
        sessions?.stopAllLanguageServers()
    }

    func clearDiagnostics(_ sessions: LanguageToolingSessionManager?) {
        sessions?.clearDiagnostics()
    }

    func prepareForRestart(
        feature: LanguageToolingFeatureModel,
        sessions: LanguageToolingSessionManager?
    ) {
        stopAllLanguageServers(sessions)
        resetWorkspaceState(feature)
    }

    func sessionsForMaintenance(
        current: LanguageToolingSessionManager?
    ) async throws -> LanguageToolingSessionManager {
        if let current {
            return current
        }
        return try await activate().sessions
    }

    /// Activates the testing extension for every language support that claims
    /// one of `files`. A single failure aborts the whole discovery: a partially
    /// registered provider set would report an incomplete test tree as if it
    /// were complete.
    func activateTestExtensions(
        for files: [URL],
        testService: LanguageTestService,
        supports: @MainActor ([URL]) -> [LanguageSupportDeclaration]
    ) async -> Bool {
        for support in supports(files) where support.testingModuleID != nil {
            do {
                let value = try await runtime.activateCapability(
                    .languageTestingExtension(support.id)
                )
                guard let provider = value as? any LanguageTestExtensionProviding,
                      testService.registerLanguageTestExtension(
                          provider,
                          support: support
                      ) else {
                    notify("\(support.displayName) returned an invalid test provider")
                    return false
                }
            } catch {
                notify(error.localizedDescription)
                return false
            }
        }
        return true
    }

    func activateTestExtension(
        _ support: LanguageSupportDeclaration,
        testService: LanguageTestService
    ) async -> Bool {
        await activateTestExtensions(
            for: [],
            testService: testService,
            supports: { _ in [support] }
        )
    }
}
