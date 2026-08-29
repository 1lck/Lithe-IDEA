import Combine
import Foundation
import LitheDebugModule
import LitheExecutionModule

@MainActor
extension AppModel {
    struct DebugFeatureAccess {
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
    var genericDebugFeatureIfActive: GenericDebugFeatureModel? {
        debugCapability?.genericFeature as? GenericDebugFeatureModel
    }

    func activateExecutionModule() async -> ExecutionFeatureAccess? {
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
        if let genericFeature = genericDebugFeatureIfActive {
            if let workspaceURL { genericFeature.openWorkspace(at: workspaceURL) }
            return DebugFeatureAccess(genericFeature: genericFeature)
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(.debugWorkspace)
            guard let capability = value as? LitheDebugModule.DebugModuleCapability,
                  let genericFeature = capability.genericFeature as? GenericDebugFeatureModel else { return nil }
            cacheModuleCapability(capability, id: .debugWorkspace, moduleID: .debug)
            genericFeature.onStoppedLocation = { [weak self] url, line, column in
                self?.openSourceLocation(url: url, line: line, column: column)
            }
            if let workspaceURL { genericFeature.openWorkspace(at: workspaceURL) }
            observeModuleFeature(.debug, observation: genericFeature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return DebugFeatureAccess(genericFeature: genericFeature)
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }

    func restoreDebugBreakpoints(for workspaceURL: URL) async {
        guard self.workspaceURL == workspaceURL,
              let persistence = services.debugBreakpointPersistence else { return }
        do {
            guard let snapshot = try persistence.loadBreakpoints(for: workspaceURL),
                  snapshot.version == DebugBreakpointSnapshot.currentVersion,
                  !snapshot.breakpoints.isEmpty,
                  self.workspaceURL == workspaceURL else { return }
            _ = await activateDebugModule()
        } catch {
            showNotification(error.localizedDescription)
        }
    }
}
