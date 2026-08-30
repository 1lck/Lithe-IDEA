import Combine
import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheModuleAPI

@MainActor
final class DebugFeatureGraph: NSObject, DebugServiceGraph {
    let adapterSessions: DebugAdapterSessionManager
    let genericFeature: GenericDebugFeatureModel
    private var activityObservers: Set<AnyCancellable> = []
    private var adapterLease: ModuleLease?

    init(
        adapterSessions: DebugAdapterSessionManager,
        breakpointPersistence: (any DebugBreakpointPersisting)? = nil,
        breakpointRelocator: (any DebugBreakpointRelocating)? = nil,
        steppingFilterResolver: (any DebugSteppingFilterResolving)? = nil,
        steppingFilterPersistence: (any DebugSteppingFilterPersisting)? = nil
    ) {
        self.adapterSessions = adapterSessions
        genericFeature = GenericDebugFeatureModel(
            sessions: adapterSessions,
            breakpointPersistence: breakpointPersistence,
            breakpointRelocator: breakpointRelocator,
            steppingFilterResolver: steppingFilterResolver,
            steppingFilterPersistence: steppingFilterPersistence
        )
    }

    var isActive: Bool {
        adapterSessions.sessionSummaries.contains(where: \.isRunning)
    }
    var genericFeatureTarget: any GenericDebugFeatureTarget { genericFeature }
    var hasActiveDebugWork: Bool { isActive }
    func activate(context: ModuleContext) {
        configureModuleLeases { reason in context.leases.acquireLease(reason: reason) }
    }
    func prepareForSleep() async throws {
        guard !isActive else { throw FeatureModuleSleepError.activeWork("A debug session is still active.") }
    }

    func configureModuleLeases(acquire: @escaping @MainActor (String) -> ModuleLease) {
        let activeFeature = genericFeature.$state.map {
            ![.idle, .terminated, .failed].contains($0)
        }
        let activeSessions = adapterSessions.$sessionSummaries.map { summaries in
            summaries.contains(where: \.isRunning)
        }
        Publishers.CombineLatest(activeFeature, activeSessions)
            .map { $0 || $1 }
            .removeDuplicates().sink { [weak self] active in
                guard let self else { return }
                if active, adapterLease == nil { adapterLease = acquire("Debug adapter session is active") }
                if !active { adapterLease?.release(); adapterLease = nil }
            }.store(in: &activityObservers)
    }

    func stop() {
        adapterSessions.stopAll()
        adapterLease?.release(); adapterLease = nil
        activityObservers.removeAll()
    }

}
