import Foundation

final class MacWorkspaceLanguageServerPreferencesStore: WorkspaceLanguageServerPreferencesStoring {
    private static let keyPrefix = "lithe.workspace-language-servers.disabled."
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func disabledProviderIDs(for workspaceURL: URL) -> Set<String> {
        Set(store.stringArray(forKey: key(for: workspaceURL)) ?? [])
    }

    func saveDisabledProviderIDs(_ providerIDs: Set<String>, for workspaceURL: URL) {
        store.set(providerIDs.sorted(), forKey: key(for: workspaceURL))
    }

    private func key(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
