import Foundation
import LitheModuleAPI

// Note: Java 独立分发与迁移见 .agents/notes/implemented/architecture/2026-10-25-java-plugin-distribution-foundation.md

/// Suggests installation only when Java is needed and the package is absent.
/// Disabled, removed and staged packages keep their existing management flow;
/// no suggestion installs a package or changes a saved enablement choice.
enum JavaPluginTransition {
    static func shouldSuggest(files: [URL], installedPluginIDs: Set<PluginID>) -> Bool {
        guard !installedPluginIDs.contains(OfficialPluginCatalog.javaPluginID),
              let java = OfficialPluginCatalog.entry(for: OfficialPluginCatalog.javaPluginID) else { return false }
        return files.contains {
            java.fileExtensions.contains($0.pathExtension.lowercased())
                || java.projectFileNames.contains($0.lastPathComponent.lowercased())
        }
    }
}
