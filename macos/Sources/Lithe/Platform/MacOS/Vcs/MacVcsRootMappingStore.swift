import Foundation
import LitheCoreContracts

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// The VCS chosen for each ambiguous directory, per workspace, in the app's
/// preferences. Detection drops mappings whose directory is no longer
/// ambiguous.
struct MacVcsRootMappingStore: VcsRootMappingStoring {
    private static let keyPrefix = "Vcs.RootMappings."
    let store: any KeyValueStore

    func mappings(workspaceURL: URL) -> [VcsRootMapping] {
        guard let data = store.data(forKey: Self.key(workspaceURL)),
              let mappings = try? JSONDecoder().decode([VcsRootMapping].self, from: data) else { return [] }
        return mappings
    }

    func setMappings(_ mappings: [VcsRootMapping], workspaceURL: URL) {
        let key = Self.key(workspaceURL)
        guard !mappings.isEmpty else {
            store.set(nil, forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        store.set(try? encoder.encode(mappings.sorted { $0.id < $1.id }), forKey: key)
    }

    private static func key(_ workspaceURL: URL) -> String {
        keyPrefix + MacPluginStateDirectories.workspaceDigest(workspaceURL)
    }
}
