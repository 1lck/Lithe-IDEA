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
    @Published package private(set) var updatingServiceExecutionID: String?
    @Published package private(set) var serviceUpdateMessage: String?
    @Published package private(set) var serviceUpdateSessionID: String?
    @Published package private(set) var serviceUpdateExecutionID: String?

    package func canUpdateService(_ session: RunSession) -> Bool {
        guard session.isRunning, let target = session.javaUpdateTarget,
              session.javaUpdateSource != nil else { return false }
        return target.classPaths.contains {
            URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("spring-boot-devtools-")
                && $0.hasSuffix(".jar")
        }
    }

    package func updateService(
        _ session: RunSession,
        build: (JavaDebugLaunchTarget, URL) async throws -> Void
    ) async {
        guard updatingServiceExecutionID == nil, canUpdateService(session),
              let target = session.javaUpdateTarget, let source = session.javaUpdateSource else { return }
        updatingServiceExecutionID = session.executionID
        serviceUpdateSessionID = session.id
        serviceUpdateExecutionID = session.executionID
        serviceUpdateMessage = "Saving and compiling service changes…"
        defer { updatingServiceExecutionID = nil }
        func isCurrent() -> Bool {
            moduleSessions.contains { $0.executionID == session.executionID && $0.isRunning }
        }
        do {
            try await build(target, source)
            guard isCurrent() else { serviceUpdateMessage = nil; return }
            serviceUpdateMessage = "Compilation finished. Check service logs for the DevTools restart. If a trigger file is configured, update it to restart."
        } catch {
            guard isCurrent() else { serviceUpdateMessage = nil; return }
            serviceUpdateMessage = "Could not update service: " + error.localizedDescription
        }
    }

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
        return configuration.id
    }
    package var isSelectedConfigurationRunning: Bool {
        guard let configuration = selectedConfiguration else { return false }
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
    package var mavenProfiles: [MavenProfile] { service.mavenProfiles }
    package var primaryExecutionID: String? { service.primaryExecutionID }
    package var moduleSessions: [RunSession] { service.moduleSessions }
    package var portConflicts: [RunPortConflict] { service.portConflicts }
    package var configurationStatus: ProjectRunConfigurationStatus { service.configurationStatus }
    package var requiresConfigurationGeneration: Bool { service.requiresConfigurationGeneration }
    package var configurationDiagnostics: [RunConfigurationDiagnostic] { service.configurationDiagnostics }
    package var generationState: RunConfigurationGenerationState { service.generationState }
    package var javaDiscoveryStatus: JavaDiscoveryStatus { service.javaDiscoveryStatus }
    package var projectLoadState: ProjectLoadState { service.projectLoadState }
    package func reportGenerationProjectNotReady() { service.reportGenerationProjectNotReady() }
    package var recoveryAction: RunConfigurationRecoveryAction { service.recoveryAction }
    package var recoveryPath: String? { service.recoveryPath }
    package var configurationSaveError: String? { service.configurationSaveError }
    package var projectToolchain: ProjectToolchainSelection { service.projectToolchain }
    package var savedProjectToolchain: ProjectToolchainSelection? { service.savedProjectToolchain }
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

    package func validateProviderGeneration(for configuration: RunConfiguration) throws {
        try service.validateProviderGeneration(for: configuration)
    }

    package func buildProviderHints(for configuration: RunConfiguration, toolchain: String, workingDirectory: String) throws -> BuildProviderHints {
        try service.buildProviderHints(for: configuration, toolchain: toolchain, workingDirectory: workingDirectory)
    }

    package func options(for configuration: RunConfiguration) -> RunOptions {
        service.options(for: configuration)
    }

    package func configuredServerPort(for configuration: RunConfiguration) -> Int? {
        service.configuredServerPort(for: configuration)
    }

    package func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        service.source(for: configuration)
    }

    /// Applies the same selected configuration side effects used by Run,
    /// including project-scoped Java runtime selection, before Debug starts.
    package func select(_ configuration: RunConfiguration) {
        service.select(configuration)
    }

    package func serviceURL(for configuration: RunConfiguration) -> URL? {
        service.serviceURL(for: configuration)
    }

    @discardableResult
    package func saveProjectToolchain(_ toolchain: ProjectToolchainSelection) -> Bool {
        service.saveProjectToolchain(toolchain)
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

    @discardableResult
    package func createConfiguration(_ draft: RunConfigurationDraft) -> Bool {
        service.createConfiguration(draft)
    }

    package func runAllServices(
        javaLaunches: [String: JavaDebugLaunchTarget] = [:]
    ) {
        service.runAllServices(javaLaunches: javaLaunches)
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

    /// Adds JDT's view of the generated Java entries to the Run diagnostics.
    package func reportJavaEntrypointFreshness(_ entrypoints: JavaEntrypoints) async {
        await service.reportJavaEntrypointFreshness(entrypoints)
    }

    package func generateRunConfigurations(
        javaDiscovery: JavaEntrypointDiscovery = .notJava,
        automatic: Bool = false
    ) async {
        isGenerationConfirmationPresented = false
        await service.generateRunConfigurations(javaDiscovery: javaDiscovery, automatic: automatic)
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
    package func runSelected(
        currentFileURL: URL?,
        javaLaunch: JavaDebugLaunchTarget? = nil
    ) {
        service.runSelected(currentFileURL: currentFileURL, javaLaunch: javaLaunch)
    }
    package func startConfiguration(
        _ configuration: RunConfiguration,
        javaLaunch: JavaDebugLaunchTarget? = nil
    ) {
        service.startConfiguration(configuration, javaLaunch: javaLaunch)
    }
    package func restart(javaLaunch: JavaDebugLaunchTarget? = nil) {
        service.restart(javaLaunch: javaLaunch)
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

package typealias JavaRunFeatureModel = RunFeatureModel
