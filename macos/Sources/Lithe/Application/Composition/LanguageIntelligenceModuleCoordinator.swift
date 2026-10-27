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
    private let awaitShutdown: () async throws -> Void
    private let bind: (LanguageIntelligenceCapability) -> Void
    private let notify: @MainActor (String) -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        awaitShutdown: @escaping () async throws -> Void,
        bind: @escaping (LanguageIntelligenceCapability) -> Void,
        notify: @escaping @MainActor (String) -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.awaitShutdown = awaitShutdown
        self.bind = bind
        self.notify = notify
    }

    func activate() async throws -> LanguageIntelligenceCapability {
        // A cached capability can still belong to the graph being torn down.
        try await awaitShutdown()
        try Task.checkCancellation()
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

    func sessionsForMaintenance() async throws -> LanguageToolingSessionManager {
        try await activate().sessions
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
        do {
            try await awaitShutdown()
            try Task.checkCancellation()
        } catch {
            if !error.isCancellation { notify(error.localizedDescription) }
            return false
        }
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
                if !error.isCancellation { notify(error.localizedDescription) }
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
