import Combine
import Foundation
import LitheDebugModule
import LitheModuleAPI

@MainActor
final class DebugFeatureGraph: NSObject, DebugServiceGraph {
    let java: JavaDebugService
    let adapterSessions: DebugAdapterSessionManager
    let javaFeature: JavaDebugFeatureModel
    let genericFeature: GenericDebugFeatureModel
    private var activityObservers: Set<AnyCancellable> = []
    private var javaLease: ModuleLease?
    private var adapterLease: ModuleLease?

    init(java: JavaDebugService, adapterSessions: DebugAdapterSessionManager) {
        self.java = java; self.adapterSessions = adapterSessions
        javaFeature = JavaDebugFeatureModel(service: java)
        genericFeature = GenericDebugFeatureModel(sessions: adapterSessions)
    }

    var isActive: Bool { java.state != .idle || !adapterSessions.activeAdapterIDs.isEmpty }
    var javaFeatureTarget: any JavaDebugFeatureTarget { javaFeature }
    var genericFeatureTarget: any GenericDebugFeatureTarget { genericFeature }
    var hasActiveDebugWork: Bool { isActive }
    func activate(context: ModuleContext) {
        configureModuleLeases { reason in context.leases.acquireLease(reason: reason) }
    }
    func prepareForSleep() async throws {
        guard !isActive else { throw FeatureModuleSleepError.activeWork("A debug session is still active.") }
    }

    func configureModuleLeases(acquire: @escaping @MainActor (String) -> ModuleLease) {
        java.$state.map { $0 != .idle }.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, javaLease == nil { javaLease = acquire("Java debug session is active") }
            if !active { javaLease?.release(); javaLease = nil }
        }.store(in: &activityObservers)
        genericFeature.$state.map { ![.idle, .terminated, .failed].contains($0) }
            .removeDuplicates().sink { [weak self] active in
                guard let self else { return }
                if active, adapterLease == nil { adapterLease = acquire("Debug adapter session is active") }
                if !active { adapterLease?.release(); adapterLease = nil }
            }.store(in: &activityObservers)
    }

    func stop() {
        java.stop(); adapterSessions.stopAll()
        javaLease?.release(); javaLease = nil
        adapterLease?.release(); adapterLease = nil
        activityObservers.removeAll()
    }

}
