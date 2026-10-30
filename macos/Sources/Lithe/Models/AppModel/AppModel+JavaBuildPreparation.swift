import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Save/build/JDT ordering for Java Run and Debug; Maven owns resource semantics.
@MainActor
extension AppModel {
    func prepareJavaRunLaunch(
        for configuration: RunConfiguration,
        identity: WorkspaceIdentity
    ) async throws -> JavaDebugLaunchTarget? {
        try await prepareCurrentProviderGeneration(configuration: configuration, identity: identity)
        guard configuration.usesJavaProjectPreparation else { return nil }
        guard let workspaceURL,
              let sourceURL = runWorkflowCoordinator.sourceURLForDebug(
                configuration: configuration,
                activeDocument: activeDocument,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
              ) else {
            throw RunConfigurationOperationFailure(
                message: L10n.string("The Java source for \(configuration.name) could not be resolved.")
            )
        }
        let languageImport = try await prepareJavaBuildResources(configuration: configuration, fileURL: sourceURL, identity: identity)
        let revision = buildSystemsFeatureIfActive?.inputRevision
        let operation = buildSystemsFeatureIfActive?.operation?.id
        let sessions = try await languageSessionsForWorkspaceMaintenance(for: identity)
        guard isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
        let preparation = try await sessions.prepareJavaRunLaunchTarget(fileURL: sourceURL, rootURL: workspaceURL, languageImport: languageImport)
        let javaRevision = sessions.javaImportRevision
        let target = try await resolveJavaLaunchPreparation(preparation, identity: identity)
        guard isCurrentWorkspace(identity), !Task.isCancelled, buildSystemsFeatureIfActive?.inputRevision == revision,
              buildSystemsFeatureIfActive?.operation?.id == operation, sessions.javaImportRevision == javaRevision else { throw CancellationError() }
        return JavaDebugLaunchTarget(mainClass: target.mainClass, projectName: target.projectName,
            modulePaths: target.modulePaths, classPaths: target.classPaths, buildPrepared: true)
    }

    func prepareCurrentProviderGeneration(configuration: RunConfiguration, identity: WorkspaceIdentity) async throws {
        guard configuration.requiresProviderGeneration else { return }
        try await prepareBuildLanguageImport()
        guard let builds = buildSystemsFeatureIfActive, let run = runFeatureIfActive else { throw CancellationError() }
        try await builds.prepareRunGenerationModels(workspace: identity.url)
        guard isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
        try run.validateProviderGeneration(for: configuration)
    }

    /// Java owns this public task convention; Maven owns the resource semantics.
    @discardableResult
    func prepareJavaBuildResources(configuration: RunConfiguration, fileURL: URL, identity: WorkspaceIdentity) async throws -> JavaLanguageImportConfiguration {
        guard configuration.usesJavaProjectPreparation else { return JavaLanguageImportConfiguration() }
        guard isCurrentWorkspace(identity), await saveAllDocuments(), isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
        try await prepareBuildLanguageImport()
        guard let builds = buildSystemsFeatureIfActive, let run = runFeatureIfActive else { throw CancellationError() }
        try await prepareCurrentProviderGeneration(configuration: configuration, identity: identity)
        let options = run.options(for: configuration)
        var overrides: [String: ToolingJSONValue] = [:]
        if !options.activeProfiles.isEmpty { overrides["profiles"] = .array(options.activeProfiles.sorted().map(ToolingJSONValue.string)) }
        let prepared = try await builds.prepareLanguageRun(fileURL: fileURL, workspace: identity.url,
            mainTask: "java-prepare-run-main", testTask: "java-prepare-run-test", optionOverrides: overrides,
            tool: { root in try run.buildProviderHints(for: configuration, toolchain: "project-maven", workingDirectory: root) },
            isCurrent: { [weak self] in self?.isCurrentWorkspace(identity) == true })
        guard case .maven(let context)? = prepared else {
            throw RunConfigurationOperationFailure(message: L10n.string("Load the current build model and enable its provider before running this configuration."))
        }
        let current = try javaLanguageImportConfiguration(rootURL: identity.url)
        return JavaLanguageImportConfiguration(mavenContext: context, javaGradle: current.javaGradle)
    }

}
