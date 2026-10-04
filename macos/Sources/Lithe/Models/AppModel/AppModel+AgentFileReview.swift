import Foundation
import LitheAgentConversationModule

extension AppModel {
    /// Synchronize native editor input before deciding whether rollback is safe.
    /// External-change observation reloads clean buffers after the guarded write.
    func restoreAgentFile(_ change: AgentFileChange) async throws {
        guard let workspaceURL, let url = AgentToolDetails.Location(path: change.path).fileURL(in: workspaceURL) else {
            throw AgentEditRestoreError.outsideWorkspace
        }
        guard agentConversationFeatureIfActive?.hasRespondingConversation != true else {
            throw AgentConversationError.sessionBusy
        }
        for document in documentFeature.editorDocuments where document.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                document.withSynchronizedEditor { continuation.resume(with: $0) }
            }
            guard !document.isDirty else { throw AgentEditRestoreError.dirtyBuffer }
        }
        try Task.checkCancellation()
        guard self.workspaceURL == workspaceURL else { throw AgentEditRestoreError.outsideWorkspace }
        try await services.agentEditRestorer.restore(change, in: workspaceURL)
        documentFeature.processExternalChanges([url])
    }
}
