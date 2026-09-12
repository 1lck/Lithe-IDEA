import Foundation

/// Stores the user's language-server choices independently for each workspace.
protocol WorkspaceLanguageServerPreferencesStoring {
    func disabledProviderIDs(for workspaceURL: URL) -> Set<String>
    func saveDisabledProviderIDs(_ providerIDs: Set<String>, for workspaceURL: URL)
}
