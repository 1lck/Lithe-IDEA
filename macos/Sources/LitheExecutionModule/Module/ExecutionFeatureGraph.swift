import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package final class ExecutionFeatureGraph: NSObject, ExecutionServiceGraph {
    package let run: RunService
    package let tests: LanguageTestService
    package let runFeature: RunFeatureModel
    package let projectDevelopment: ProjectDevelopmentFeatureModel
    /// Nil when the host runs no plugin build systems.
    package let buildSystems: BuildSystemService?
    package let buildSystemsFeature: BuildSystemsFeatureModel?
    private var activityObservers: Set<AnyCancellable> = []
    private var runLease: ModuleLease?
    private var testLease: ModuleLease?
    private var buildLease: ModuleLease?

    package init(
        run: RunService,
        tests: LanguageTestService,
        buildSystems: BuildSystemService? = nil
    ) {
        self.run = run; self.tests = tests
        self.buildSystems = buildSystems
        buildSystemsFeature = buildSystems.map(BuildSystemsFeatureModel.init(service:))
        runFeature = RunFeatureModel(service: run)
        projectDevelopment = ProjectDevelopmentFeatureModel(runFeature: runFeature)
        run.configureBuildLanguageImportProvider { [weak buildSystems] workspace, root in
            try buildSystems?.languageImport(workspaceURL: workspace, root: root) ?? JavaLanguageImportConfiguration()
        }
        run.configureBuildProviderRuns(start: { [weak buildSystems] configuration, workspace in
            buildSystems?.runProviderConfiguration(configuration, workspace: workspace)
        }, cancel: { [weak buildSystems] id in buildSystems?.cancelRun(id) })
        buildSystems?.runEnded.sink { [weak run] ended in
            let message: String? = if case .failed(let message) = ended.state { message } else { nil }
            run?.finishBuildPreparation(ended.runID, message: message)
        }.store(in: &activityObservers)
        run.configureBuildModels { [weak buildSystems] in
            buildSystems?.entries.filter { $0.modelState == .loaded && !$0.isReloadRequired }.compactMap(\.model) ?? []
        }
        run.configureBuildProjectOwnership { [weak buildSystems] in try buildSystems?.runProjectOwnership() ?? [] }
        run.configureProviderConfigurationRuns(source: { [weak buildSystems] inputs, root in
            buildSystems?.configurationRunSource(inputs: inputs, instanceRoot: root)
        }) { [weak buildSystems] inputs, root, workspace, hints, current, progress in
            guard let buildSystems else { throw CancellationError() }
            return try await buildSystems.prepareConfigurationRun(inputs: inputs, instanceRoot: root, workspace: workspace,
                tool: hints, isCurrent: current, progress: progress)
        }

        buildSystems?.providerSourcesChanged.sink { [weak run] sources in
            run?.retainProviderConfigurations(sources)
        }.store(in: &activityObservers)
        buildSystems?.runGenerationInputsChanged.sink { [weak run] in
            run?.requestProviderGenerationInspection()
        }.store(in: &activityObservers)

    }

    package var isActive: Bool {
        run.isRunning || run.hasRunningServices || tests.isRunning
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
        // Provider teardown publishes input changes; detach before cancelling
        // inspections so shutdown cannot enqueue new work in the stopped graph.
        activityObservers.removeAll()
        run.cancelProviderGenerationInspection()
        run.stop(); run.stopAllServices(); tests.stop(); buildSystems?.stop()
        releaseLeases()
    }

    private func releaseLeases() {
        runLease?.release(); runLease = nil
        testLease?.release(); testLease = nil
        buildLease?.release(); buildLease = nil
    }
}

private struct ExecutionModuleSleepError: LocalizedError {
    let errorDescription: String? = "Build, run, or test work is still active."
    static let activeWork = Self()
}
