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
    /// Nil when the host runs no plugin build systems.
    package let buildSystems: BuildSystemService?
    package let buildSystemsFeature: BuildSystemsFeatureModel?
    private var activityObservers: Set<AnyCancellable> = []
    private var mavenLease: ModuleLease?
    private var runLease: ModuleLease?
    private var testLease: ModuleLease?
    private var buildLease: ModuleLease?

    package init(
        maven: MavenService,
        run: RunService,
        tests: LanguageTestService,
        buildSystems: BuildSystemService? = nil
    ) {
        self.maven = maven; self.run = run; self.tests = tests
        self.buildSystems = buildSystems
        buildSystemsFeature = buildSystems.map(BuildSystemsFeatureModel.init(service:))
        let mavenFeature = MavenFeatureModel(service: maven)
        self.mavenFeature = mavenFeature
        runFeature = RunFeatureModel(service: run)
        projectDevelopment = ProjectDevelopmentFeatureModel(mavenFeature: mavenFeature, runFeature: runFeature)
        run.configureMavenContextProvider { [weak maven] in
            maven?.launchContext
        }
        maven.onProjectReloaded = { [weak run] workspace, project in
            run?.acceptMavenProject(project, at: workspace)
        }
        maven.$dependencyStates.dropFirst().sink { [weak run] _ in
            Task { @MainActor [weak run] in
                run?.syncLanguageDependencyPaths(languageID: "java")
            }
        }.store(in: &activityObservers)
    }

    package var isActive: Bool {
        maven.isRunning || maven.isResolvingDependencies || maven.isReloading
            || run.isRunning || run.hasRunningServices || tests.isRunning
            || buildSystems?.hasActiveWork == true
    }
    package var hasActiveExecutionWork: Bool { isActive }
    package func activate(context: ModuleContext) {
        configureModuleLeases { reason in context.leases.acquireLease(reason: reason) }
    }
    package func prepareForSleep() async throws {
        guard !isActive else { throw ExecutionModuleSleepError.activeWork }
    }

    package func configureModuleLeases(acquire: @escaping @MainActor (String) -> ModuleLease) {
        Publishers.CombineLatest3(maven.$taskState, maven.$dependencyStates, maven.$isReloading).map { state, dependencies, reloading in
            let buildIsActive = switch state {
            case .running, .stopping: true
            case .idle, .cancelled, .failed: false
            }
            let dependenciesAreActive = dependencies.values.contains {
                if case .loading = $0 { return true }
                return false
            }
            return buildIsActive || dependenciesAreActive || reloading
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
        buildSystems?.$hasActiveWork.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, buildLease == nil { buildLease = acquire("Build system command is running") }
            if !active { buildLease?.release(); buildLease = nil }
        }.store(in: &activityObservers)
    }

    /// Ends every process this graph started. Service sessions outlive the
    /// run that launched them, so they are stopped here as well: nothing the
    /// IDE started may keep running after the session that owns it is gone.
    package func stop() {
        maven.stop(); run.stop(); run.stopAllServices(); tests.stop(); buildSystems?.stop()
        releaseLeases()
        activityObservers.removeAll()
    }

    private func releaseLeases() {
        mavenLease?.release(); mavenLease = nil
        runLease?.release(); runLease = nil
        testLease?.release(); testLease = nil
        buildLease?.release(); buildLease = nil
    }
}


private struct ExecutionModuleSleepError: LocalizedError {
    let errorDescription: String? = "Build, run, or test work is still active."
    static let activeWork = Self()
}
