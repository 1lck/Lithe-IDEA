import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Saves the Java workspace before requesting the shared launch preparation.
@MainActor
extension AppModel {
    func saveJavaWorkspaceForLaunch(identity: WorkspaceIdentity) async throws {
        guard isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
        let saved = await saveAllDocuments()
        guard isCurrentWorkspace(identity), !Task.isCancelled else { throw CancellationError() }
        guard saved else {
            throw RunConfigurationOperationFailure(
                message: L10n.string("Java launch stopped because modified files could not be saved.")
            )
        }
        // A prior manual/automatic save may have reached disk while its LSP
        // notification failed. Retry clean buffers too and propagate failures
        // before asking JDT to build; disk persistence alone is not readiness.
        for document in openDocuments where !document.isReadOnly {
            try languageToolingSessionsIfActive?.notifyDocumentSaved(
                document.url, text: document.savedText, currentText: document.text)
        }
    }

    func prepareJavaRunLaunch(
        for configuration: RunConfiguration,
        identity: WorkspaceIdentity
    ) async throws -> JavaDebugLaunchTarget? {
        guard configuration.usesJavaProjectPreparation else { return nil }
        // JDT must compile the current workspace, including dirty dependencies
        // outside the selected source. A failed save ends this launch attempt.
        try await saveJavaWorkspaceForLaunch(identity: identity)
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
        let sessions = try await languageSessionsForWorkspaceMaintenance(for: identity)
        guard isCurrentWorkspace(identity), !Task.isCancelled else {
            throw CancellationError()
        }
        let preparation = try await sessions.prepareJavaRunLaunchTarget(
            fileURL: sourceURL,
            rootURL: workspaceURL,
            mainClass: configuration.mainClass
        )
        return try await resolveJavaLaunchPreparation(preparation, identity: identity)
    }
}
