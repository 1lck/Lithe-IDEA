import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// UI-facing projection for Maven state and commands.
/// The view layer does not depend on MavenService or its process adapter.
@MainActor
package final class MavenFeatureModel: ObservableObject {
    private let service: MavenService
    private var observation: AnyCancellable?

    package init(service: MavenService) {
        self.service = service
        observation = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    package var project: MavenProject? { service.project }
    package var isLoadingProject: Bool { service.isLoadingProject }
    package var isRunning: Bool { service.isRunning }
    package var runningTitle: String? { service.runningTitle }
    package var output: String { service.output }
    package var issues: [MavenBuildIssue] { service.issues }
    package var lastExitCode: Int32? { service.lastExitCode }

    package func loadProject(at workspaceURL: URL, files: [URL]) async {
        await service.loadProject(at: workspaceURL, files: files)
    }

    package func run(phase: MavenLifecyclePhase, module: MavenModule?, profiles: Set<String>) {
        service.run(phase: phase, module: module, profiles: profiles)
    }

    package func reset() { service.reset() }

    package func stop() {
        service.stop()
    }

    package func clearOutput() {
        service.clearOutput()
    }

}

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
    package var selectedConfiguration: RunConfiguration? { service.selectedConfiguration }
    package var lastRunFileURL: URL? { service.lastRunFileURL }
    package var lastConfiguration: RunConfiguration? { service.lastConfiguration }
    package var isLoadingProject: Bool { service.isLoadingProject }
    package var isRunning: Bool { service.isRunning }
    package var runningTitle: String? { service.runningTitle }
    package var output: String { service.output }
    package var lastExitCode: Int32? { service.lastExitCode }
    package var mavenProfiles: [MavenProfile] { service.mavenProfiles }
    package var moduleSessions: [RunSession] { service.moduleSessions }
    package var portConflicts: [RunPortConflict] { service.portConflicts }
    package var configurationStatus: ProjectRunConfigurationStatus { service.configurationStatus }
    package var configurationDiagnostics: [RunConfigurationDiagnostic] { service.configurationDiagnostics }
    package var generationState: RunConfigurationGenerationState { service.generationState }
    package var recoveryAction: RunConfigurationRecoveryAction { service.recoveryAction }
    package var recoveryPath: String? { service.recoveryPath }
    package var configurationSaveError: String? { service.configurationSaveError }
    package var projectToolchain: ProjectToolchainSelection { service.projectToolchain }
    package var blockingToolchainDiagnostic: RunConfigurationDiagnostic? {
        service.blockingToolchainDiagnostic(for: service.selectedConfiguration)
    }
    package var sourceSearchRoots: [URL] { service.sourceSearchRoots }

    package func options(for configuration: RunConfiguration) -> RunOptions {
        service.options(for: configuration)
    }

    package func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        service.source(for: configuration)
    }

    package func serviceURL(for configuration: RunConfiguration) -> URL? {
        service.serviceURL(for: configuration)
    }

    @discardableResult
    package func saveEditorChanges(
        _ options: RunOptions,
        toolchain: ProjectToolchainSelection,
        for configuration: RunConfiguration,
        scope: RunConfigurationSaveScope
    ) -> Bool {
        service.saveEditorChanges(
            options,
            toolchain: toolchain,
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

    package func runAllServices() {
        service.runAllServices()
    }

    package func stopAllServices() {
        service.stopAllServices()
    }

    package func startConfiguration(_ configuration: RunConfiguration) {
        service.startConfiguration(configuration)
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

    package var projectLoadState: ProjectLoadState { service.projectLoadState }

    package func isProjectReady(for workspace: URL, snapshotID: UUID?) -> Bool {
        service.isProjectReady(for: workspace, snapshotID: snapshotID)
    }

    package func loadProject(
        at workspaceURL: URL,
        files: [URL],
        mavenProject: MavenProject?,
        snapshotID: UUID? = nil
    ) async {
        await service.loadProject(
            at: workspaceURL,
            files: files,
            mavenProject: mavenProject,
            snapshotID: snapshotID
        )
    }

    package func generateRunConfigurations() async {
        isGenerationConfirmationPresented = false
        await service.generateRunConfigurations()
    }

    package func requestRunConfigurationGeneration(intent: RunConfigurationGenerationIntent = .identifyOnly) {
        guard recoveryAction != .upgradeApplication else { return }
        generationIntent = intent
        isGenerationConfirmationPresented = true
    }

    package func select(_ configuration: RunConfiguration) { service.select(configuration) }
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
    package func runSelected(currentFileURL: URL?) { service.runSelected(currentFileURL: currentFileURL) }
    package func restart() { service.restart() }
    package func stop() { service.stop() }
    package func reset() { service.reset() }
}

/// Coordinates project-scoped build and run loading without making AppModel
/// own build-system sequencing. Language-specific project loaders can later be
/// added here without changing the workspace/UI composition boundary.
@MainActor
package final class ProjectDevelopmentFeatureModel {
    private let mavenFeature: MavenFeatureModel
    private let runFeature: RunFeatureModel

    package init(mavenFeature: MavenFeatureModel, runFeature: RunFeatureModel) {
        self.mavenFeature = mavenFeature
        self.runFeature = runFeature
    }

    package func isRunProjectReady(for workspace: URL, snapshotID: UUID?) -> Bool {
        runFeature.isProjectReady(for: workspace, snapshotID: snapshotID)
    }

    package func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID? = nil) async {
        // Maven is one build-system Provider, not a workspace prerequisite.
        // Avoid scanning every project as Maven; non-Maven ecosystems should
        // reach the generic run pipeline without paying for Java discovery.
        let hasMavenDescriptor = files.contains { file in
            file.lastPathComponent.lowercased() == "pom.xml"
        }
        if hasMavenDescriptor {
            await mavenFeature.loadProject(at: workspaceURL, files: files)
        } else {
            mavenFeature.reset()
        }
        await runFeature.loadProject(
            at: workspaceURL,
            files: files,
            mavenProject: mavenFeature.project,
            snapshotID: snapshotID
        )
    }
}

package typealias JavaRunFeatureModel = RunFeatureModel
