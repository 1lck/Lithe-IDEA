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

}
