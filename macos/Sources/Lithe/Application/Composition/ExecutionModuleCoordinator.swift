import Combine
import LitheApplicationKernel
import LitheExecutionModule
import LitheModuleAPI

/// Owns activation and observation of the execution module capability.
@MainActor
final class ExecutionModuleCoordinator {
    private let runtime: ModuleRuntime
    private let store: ModuleCapabilityStore
    private let awaitShutdown: () async -> Void
    private let onChange: () -> Void
    private let onError: (String) -> Void

    init(
        runtime: ModuleRuntime,
        store: ModuleCapabilityStore,
        awaitShutdown: @escaping () async -> Void,
        onChange: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self.store = store
        self.awaitShutdown = awaitShutdown
        self.onChange = onChange
        self.onError = onError
    }

    func activate() async -> ExecutionModuleCapability? {
        await awaitShutdown()
        if let capability: ExecutionModuleCapability = store.capability(.executionWorkspace) {
            return capability
        }
        do {
            let value = try await runtime.activateCapability(ModuleCapabilityID.executionWorkspace)
            guard let capability = value as? ExecutionModuleCapability else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .execution, capability: .executionWorkspace
                )
            }
            store.cache(capability, id: .executionWorkspace, moduleID: .execution)
            store.observe(.execution, observation: capability.runFeature.objectWillChange.sink { [weak self] (_: ()) in
                self?.onChange()
            })
            store.observe(.execution, observation: capability.testService.objectWillChange.sink { [weak self] (_: ()) in
                self?.onChange()
            })
            return capability
        } catch {
            onError(error.localizedDescription)
            return nil
        }
    }

    func activateAccess() async -> ExecutionFeatureAccess? {
        guard let capability = await activate() else { return nil }
        return ExecutionFeatureAccess(
            mavenFeature: capability.mavenFeature,
            runFeature: capability.runFeature,
            tests: capability.testService,
            projectDevelopment: capability.projectDevelopment
        )
    }

    func resetFeatures(
        maven: MavenFeatureModel?,
        run: RunFeatureModel?,
        tests: LanguageTestService?
    ) {
        maven?.reset()
        run?.reset()
        tests?.reset()
    }

    func stopFeatures(maven: MavenFeatureModel?, run: RunFeatureModel?) {
        maven?.stop()
        run?.stop()
    }

    func resetTests(_ tests: LanguageTestService?) {
        tests?.reset()
    }

    func stopTests(_ tests: LanguageTestService?) {
        tests?.stop()
    }
}
