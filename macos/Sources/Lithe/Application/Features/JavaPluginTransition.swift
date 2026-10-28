import Foundation
import LitheModuleAPI

// Note: Java 独立分发与迁移见 .agents/notes/implemented/architecture/2026-10-25-java-plugin-distribution-foundation.md

/// Suggests installation only when Java is needed and the package is absent.
/// Disabled, staged and pending-uninstall packages keep their management flow.
/// Removed packages can be restored explicitly; a suggestion never installs one.
enum JavaPluginTransition {
    static func shouldSuggest(files: [URL], plugins: [PluginManagementSnapshot]) -> Bool {
        guard !plugins.contains(where: {
            $0.id == OfficialPluginCatalog.javaPluginID
                && ($0.installationStatus != .removed || $0.hasChangesPendingRestart)
        }),
              let java = OfficialPluginCatalog.entry(for: OfficialPluginCatalog.javaPluginID) else { return false }
        return files.contains {
            java.fileExtensions.contains($0.pathExtension.lowercased())
                || java.projectFileNames.contains($0.lastPathComponent.lowercased())
        }
    }
}
