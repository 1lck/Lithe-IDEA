import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// UI-facing projection for language-neutral run configurations and process sessions.
package enum RunConfigurationGenerationIntent: Sendable {
    case identifyOnly
    case run
    case debug
}

@MainActor
package final class RunFeatureModel: ObservableObject {
    private let service: RunService
    private var observation: AnyCancellable?
    @Published package var isGenerationConfirmationPresented = false
    package private(set) var generationIntent: RunConfigurationGenerationIntent = .identifyOnly
    /// Configuration being edited in Settings, requested there or from an
    /// editor gutter marker. Separate from the Run selection so opening
    /// an editor does not switch which log is shown.
    @Published package var editingConfigurationID: String?

    package init(service: RunService) {
        self.service = service
        observation = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    package var selectedConfigurationID: String {
        get { service.selectedConfigurationID }
        set { service.selectedConfigurationID = newValue }
    }

    package var configurations: [RunConfiguration] { service.configurations }
    package var defaultConfigurationID: String? { service.defaultConfigurationID }
    package var selectedConfiguration: RunConfiguration? { service.selectedConfiguration }
    package var lastRunFileURL: URL? { service.lastRunFileURL }
    package var lastConfiguration: RunConfiguration? { service.lastConfiguration }
    /// Project configurations share session identity across toolbar and log selection.
    /// Provider applications and Current File use the primary output stream.
    package var selectedProjectSessionID: String? {
        guard let configuration = selectedConfiguration, configuration.kind != .currentFile else { return nil }
        if service.providerDebugConfigurationID == configuration.id { return nil }
        return configuration.id
    }
    package var isSelectedConfigurationRunning: Bool {
        guard let configuration = selectedConfiguration else { return false }
        if service.providerDebugConfigurationID == configuration.id {
            return isRunning && lastConfiguration?.id == configuration.id
        }
        if configuration.kind != .currentFile && configuration.buildProvider == nil {
            return moduleSessions.contains { $0.configurationID == configuration.id && $0.isRunning }
        }
        return isRunning && lastConfiguration?.id == configuration.id
    }
    package var isLoadingProject: Bool { service.isLoadingProject }
    package var isRunning: Bool { service.isRunning || service.isPreparingBuildRun }
    package var hasBuildProviderRun: Bool { service.hasBuildProviderRun }
    @discardableResult
    package func saveBuildProviderConfiguration() -> Bool { service.saveBuildProviderConfiguration() }
    package var runningTitle: String? { service.runningTitle }
    package var output: String { service.output }
    package var lastExitCode: Int32? { service.lastExitCode }
    package var primaryExecutionID: String? { service.primaryExecutionID }
    package var providerDebugEnded: AnyPublisher<String, Never> { service.providerDebugEnded.eraseToAnyPublisher() }
    package func prepareProviderDebug(_ configuration: RunConfiguration,
        debug: @escaping @MainActor (String) throws -> BuildLaunchOptions.Debug,
        isCurrent: @escaping @MainActor @Sendable () -> Bool) async throws -> String {
        try await service.prepareProviderDebug(configuration, debug: debug, isCurrent: isCurrent)
    }
    package func isProviderDebugActive(_ operation: String) -> Bool { service.isProviderDebugActive(operation) }
    package func providerDebugProcessID(_ operation: String) -> Int32? { service.providerDebugProcessID(operation) }
    package func stopProviderDebug() { service.stopProviderDebug() }
    package var hasPluginRun: Bool { service.hasPluginRun }
    package var canRestartPluginRun: Bool { service.canRestartPluginRun }
    package var pluginRunEnded: AnyPublisher<PluginRunEnd, Never> { service.pluginRunEnded.eraseToAnyPublisher() }
    package func launchPluginRun(_ launch: PluginRunLaunch, rerun: (@MainActor () -> Void)?) throws {
        try service.launchPluginRun(launch, rerun: rerun)
    }
    @discardableResult
    package func restartPluginRun() -> Bool { service.restartPluginRun() }
    package func isPluginRunActive(_ runID: String) -> Bool { service.isPluginRunActive(runID) }
    package func pluginRunProcessID(_ runID: String) -> Int32? { service.pluginRunProcessID(runID) }
    package func stopPluginRun(_ runID: String) { service.stopPluginRun(runID) }
    package var moduleSessions: [RunSession] { service.moduleSessions }
    package var configurationStatus: ProjectRunConfigurationStatus { service.configurationStatus }
    package var requiresConfigurationGeneration: Bool { service.requiresConfigurationGeneration }
    package var configurationDiagnostics: [RunConfigurationDiagnostic] { service.configurationDiagnostics }
    package var generationState: RunConfigurationGenerationState { service.generationState }
    package var projectLoadState: ProjectLoadState { service.projectLoadState }
    package func reportGenerationProjectNotReady() { service.reportGenerationProjectNotReady() }
    package var recoveryAction: RunConfigurationRecoveryAction { service.recoveryAction }
    package var recoveryPath: String? { service.recoveryPath }
    package var configurationSaveError: String? { service.configurationSaveError }
    package var blockingToolchainDiagnostic: RunConfigurationDiagnostic? {
        service.blockingToolchainDiagnostic(for: service.selectedConfiguration)
    }
    package var sourceSearchRoots: [URL] { service.sourceSearchRoots }
    package var dependencyServices: [DependencyServiceDescriptor] { service.dependencyServices }
    package func registerDependencySource(languageID: String, displayName: String) {
        service.registerDependencySource(languageID: languageID, displayName: displayName)
    }
    package func unregisterDependencySource(languageID: String) {
        service.unregisterDependencySource(languageID: languageID)
    }
    package var dependencyRevision: Int { service.dependencyRevision }
    package var dependencyConfigurationSaveError: String? {
        service.dependencyConfigurationSaveError
    }
    package func dependencyPaths(for serviceID: String) -> DependencyPathConfiguration {
        service.dependencyPaths(for: serviceID)
    }
    package func resolveDependencies(serviceID: String) async throws -> DependencyGraph? {
        try await service.resolveDependencies(serviceID: serviceID)
    }
    package func updateDependencyPaths(
        _ paths: DependencyPathConfiguration,
        serviceID: String
    ) {
        service.updateDependencyPaths(paths, serviceID: serviceID)
    }
    package func excludeDependencyPath(_ path: String, serviceID: String) {
        service.excludeDependencyPath(path, serviceID: serviceID)
    }
    package func restoreDependencyPath(_ path: String, serviceID: String) {
        service.restoreDependencyPath(path, serviceID: serviceID)
    }
    package func markDependencyFilesChanged(_ changes: [WorkspaceFileChange]) {
        service.markDependencyFilesChanged(changes)
    }
    package func syncLanguageDependencyPaths(languageID: String) {
        service.syncLanguageDependencyPaths(languageID: languageID)
    }
    package func isProjectReady(for workspace: URL, snapshotID: UUID?) -> Bool { service.isProjectReady(for: workspace, snapshotID: snapshotID) }
    package func hasReadyInventory(for workspace: URL) -> Bool { service.hasReadyInventory(for: workspace) }

    package func options(for configuration: RunConfiguration) -> RunOptions {
        service.options(for: configuration)
    }

    package func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        service.source(for: configuration)
    }

    /// Applies the same selected configuration side effects used by Run
    /// before Debug starts.
    package func select(_ configuration: RunConfiguration) {
        service.select(configuration)
    }

    package func serviceURL(for configuration: RunConfiguration) -> URL? {
        service.serviceURL(for: configuration)
    }

    @discardableResult
    package func saveEditorChanges(
        _ options: RunOptions,
        for configuration: RunConfiguration,
        scope: RunConfigurationSaveScope
    ) -> Bool {
        service.saveEditorChanges(
            options,
            for: configuration,
            scope: scope
        )
    }

    package func resetOptions(for configuration: RunConfiguration) {
        service.resetOptions(for: configuration)
    }

    package func runAllServices() {
        service.runAllServices()
    }

    package func stopAllServices() {
        service.stopAllServices()
    }

    package func stopModule(_ session: RunSession) {
        service.stopModule(session)
    }

    package func restartModule(_ session: RunSession) {
        service.restartModule(session)
    }

    package func clearModuleOutput(_ session: RunSession) {
        service.clearModuleOutput(session)
    }

    package func clearOutput() {
        service.clearOutput()
    }

    package func loadProject(
        at workspaceURL: URL,
        files: [URL],
        snapshotID: UUID? = nil
    ) async {
        await service.loadProject(at: workspaceURL, files: files, snapshotID: snapshotID)
    }

    package func generateRunConfigurations(automatic: Bool = false) async {
        isGenerationConfirmationPresented = false
        await service.generateRunConfigurations(automatic: automatic)
    }

    package func requestRunConfigurationGeneration(intent: RunConfigurationGenerationIntent = .identifyOnly) {
        guard recoveryAction != .upgradeApplication else { return }
        generationIntent = intent
        isGenerationConfirmationPresented = true
    }

    @discardableResult
    package func registerLanguageRunExtension(
        _ provider: any LanguageRunExtensionProviding,
        support: LanguageSupportDeclaration
    ) -> Bool {
        service.registerLanguageRunExtension(provider, support: support)
    }

    package func unregisterLanguageRunExtension(languageID: String) {
        service.unregisterLanguageRunExtension(languageID: languageID)
    }
    package func runSelected(currentFileURL: URL?) {
        service.runSelected(currentFileURL: currentFileURL)
    }
    package func startConfiguration(_ configuration: RunConfiguration) {
        service.startConfiguration(configuration)
    }
    package func restart() {
        service.restart()
    }
    package func stop() { service.stop() }
    package func reset() { service.reset() }
}

/// Coordinates project-scoped build and run loading without making AppModel
/// own build-system sequencing. Language-specific project loaders can later be
/// added here without changing the workspace/UI composition boundary.
@MainActor
package final class ProjectDevelopmentFeatureModel {
    private let runFeature: RunFeatureModel

    package init(runFeature: RunFeatureModel) { self.runFeature = runFeature }

    package func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID? = nil) async {
        await runFeature.loadProject(at: workspaceURL, files: files, snapshotID: snapshotID)
    }
}
