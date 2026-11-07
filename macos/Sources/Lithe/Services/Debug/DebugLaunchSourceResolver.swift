import Foundation
import LitheCoreContracts

/// Selects the source file that anchors a Debug launch without making the
/// selected Run configuration depend on whichever editor tab is currently open.
struct DebugLaunchSourceResolver {
    /// Resolves the file a Debug launch is anchored to. Only the current-editor
    /// entry follows the active tab; every other configuration is launched by
    /// its provider and has no host-side source anchor. Returns nil in that
    /// case, so the caller never guesses a file by its extension.
    func resolve(
        configuration: RunConfiguration,
        activeDocumentURL: URL?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> URL? {
        guard configuration.usesCurrentEditorFile else { return nil }
        return activeDocumentURL?.standardizedFileURL
    }
}
