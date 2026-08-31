import Combine
import Foundation
import LitheDebugModule
import LitheExecutionModule

@MainActor
extension AppModel {
    struct DebugFeatureAccess {
        let javaFeature: JavaDebugFeatureModel
        let genericFeature: GenericDebugFeatureModel
    }
    struct ExecutionFeatureAccess {
        let mavenFeature: MavenFeatureModel
        let runFeature: RunFeatureModel
        let tests: LanguageTestService
        let projectDevelopment: ProjectDevelopmentFeatureModel
    }

    var mavenFeatureIfActive: MavenFeatureModel? { executionCapability?.mavenFeature }
    var runFeatureIfActive: RunFeatureModel? { executionCapability?.runFeature }
    var debugFeatureIfActive: JavaDebugFeatureModel? {
        debugCapability?.javaFeature as? JavaDebugFeatureModel
    }
    var genericDebugFeatureIfActive: GenericDebugFeatureModel? {
        debugCapability?.genericFeature as? GenericDebugFeatureModel
    }

    func activateExecutionModule() async -> ExecutionFeatureAccess? {
        // Run and Debug activate on demand, so they can arrive while the previous
        // session's module graph is still being torn down. Activating first would
        // hand back a run feature that teardown releases moments later, and the
        // deferred action waiting on it would never be resumed.
        await awaitModuleRuntimeShutdown()
        if let mavenFeature = mavenFeatureIfActive,
           let runFeature = runFeatureIfActive,
           let tests = languageTestServiceIfActive,
           let projectDevelopment = executionCapability?.projectDevelopment {
            return ExecutionFeatureAccess(mavenFeature: mavenFeature, runFeature: runFeature, tests: tests, projectDevelopment: projectDevelopment)
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(.executionWorkspace)
            guard let capability = value as? LitheExecutionModule.ExecutionModuleCapability else { return nil }
            let mavenFeature = capability.mavenFeature
            let runFeature = capability.runFeature
            let tests = capability.testService
            let projectDevelopment = capability.projectDevelopment
            cacheModuleCapability(capability, id: .executionWorkspace, moduleID: .execution)
            observeModuleFeature(.execution, observation: runFeature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            observeModuleFeature(.execution, observation: tests.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return ExecutionFeatureAccess(mavenFeature: mavenFeature, runFeature: runFeature, tests: tests, projectDevelopment: projectDevelopment)
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }

    func activateDebugModule() async -> DebugFeatureAccess? {
        await awaitModuleRuntimeShutdown()
        if let javaFeature = debugFeatureIfActive,
           let genericFeature = genericDebugFeatureIfActive {
            return DebugFeatureAccess(javaFeature: javaFeature, genericFeature: genericFeature)
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(.debugWorkspace)
            guard let capability = value as? LitheDebugModule.DebugModuleCapability,
                  let javaFeature = capability.javaFeature as? JavaDebugFeatureModel,
                  let genericFeature = capability.genericFeature as? GenericDebugFeatureModel else { return nil }
            cacheModuleCapability(capability, id: .debugWorkspace, moduleID: .debug)
            self.javaFeature.configureRuntime(
                mavenFeature: mavenFeatureIfActive,
                debugFeature: javaFeature
            )
            observeModuleFeature(.debug, observation: javaFeature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return DebugFeatureAccess(javaFeature: javaFeature, genericFeature: genericFeature)
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }
}
