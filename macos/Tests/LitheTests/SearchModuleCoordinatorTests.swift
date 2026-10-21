import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct SearchModuleCoordinatorTests {
    @Test
    func cancelledActivationIsNotReportedAsAFailure() async throws {
        let notifications = try await activationNotifications(throwing: CancellationError())
        #expect(notifications.isEmpty)
    }

    @Test
    func failedActivationIsStillReported() async throws {
        let notifications = try await activationNotifications(throwing: SearchActivationFailure())
        #expect(notifications == [SearchActivationFailure.message])
    }

    private func activationNotifications(throwing error: any Error) async throws -> [String] {
        let runtime = ModuleRuntime()
        let manifest = ModuleManifest(
            id: .search,
            displayName: "Search",
            scope: .workspace,
            providedCapabilities: [.searchWorkspace]
        )
        try runtime.register(ModuleFactory(manifest: manifest) {
            FailingSearchModule(manifest: manifest, error: error)
        })
        var notifications: [String] = []
        let coordinator = SearchModuleCoordinator(
            runtime: runtime,
            store: ModuleCapabilityStore(),
            onChange: {},
            onError: { notifications.append($0) }
        )
        #expect(await coordinator.activate() == nil)
        await runtime.shutdownAll()
        return notifications
    }
}

private struct SearchActivationFailure: LocalizedError {
    static let message = "Search index is unavailable"
    var errorDescription: String? { Self.message }
}

private final class FailingSearchModule: LitheModule {
    let manifest: ModuleManifest
    private let error: any Error

    init(manifest: ModuleManifest, error: any Error) {
        self.manifest = manifest
        self.error = error
    }

    func activate(context: ModuleContext) async throws { throw error }
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
