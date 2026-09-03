import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package final class ExecutionFeatureGraph: NSObject, ExecutionServiceGraph {
    package let maven: MavenService
    package let run: RunService
    package let tests: LanguageTestService
    package let mavenFeature: MavenFeatureModel
    package let runFeature: RunFeatureModel
    package let projectDevelopment: ProjectDevelopmentFeatureModel
    private var activityObservers: Set<AnyCancellable> = []
    private var mavenLease: ModuleLease?
    private var runLease: ModuleLease?
    private var testLease: ModuleLease?

    package init(maven: MavenService, run: RunService, tests: LanguageTestService) {
        self.maven = maven; self.run = run; self.tests = tests
        mavenFeature = MavenFeatureModel(service: maven)
        runFeature = RunFeatureModel(service: run)
        projectDevelopment = ProjectDevelopmentFeatureModel(mavenFeature: mavenFeature, runFeature: runFeature)
        run.configureMavenContextProvider { [weak maven] in
            maven?.launchContext
        }
    }

    package var isActive: Bool {
        maven.isRunning || maven.isResolvingDependencies || run.isRunning || tests.isRunning
    }
    package var hasActiveExecutionWork: Bool { isActive }
    package func activate(context: ModuleContext) {
        configureModuleLeases { reason in context.leases.acquireLease(reason: reason) }
    }
    package func prepareForSleep() async throws {
        guard !isActive else { throw ExecutionModuleSleepError.activeWork }
    }

    package func configureModuleLeases(acquire: @escaping @MainActor (String) -> ModuleLease) {
        Publishers.CombineLatest(maven.$taskState, maven.$dependencyStates).map { state, dependencies in
            let buildIsActive = switch state {
            case .running, .stopping: true
            case .idle, .cancelled, .failed: false
            }
            let dependenciesAreActive = dependencies.values.contains {
                if case .loading = $0 { return true }
                return false
            }
            return buildIsActive || dependenciesAreActive
        }.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, mavenLease == nil { mavenLease = acquire("Maven operation is running") }
            if !active { mavenLease?.release(); mavenLease = nil }
        }.store(in: &activityObservers)
        run.$isRunning.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, runLease == nil { runLease = acquire("Run configuration is running") }
            if !active { runLease?.release(); runLease = nil }
        }.store(in: &activityObservers)
        tests.$state.map { $0 == .running }.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, testLease == nil { testLease = acquire("Test run is active") }
            if !active { testLease?.release(); testLease = nil }
        }.store(in: &activityObservers)
    }

    package func stop() {
        maven.stop(); maven.cancelAllDependencies(); run.stop(); tests.stop()
        releaseLeases()
        activityObservers.removeAll()
    }

    private func releaseLeases() {
        mavenLease?.release(); mavenLease = nil
        runLease?.release(); runLease = nil
        testLease?.release(); testLease = nil
    }
}


private struct ExecutionModuleSleepError: LocalizedError {
    let errorDescription: String? = "Build, run, or test work is still active."
    static let activeWork = Self()
}
