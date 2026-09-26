import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Plugin management presentation")
struct PluginManagementPresentationTests {
    @Test
    func languagePluginsAreGroupedSeparatelyFromStandalonePlugins() throws {
        let pythonManifest = try #require(
            BundledLanguagePluginCatalog.manifests.first { $0.languageSupports?.first?.id == "python" }
        )
        let rustManifest = try #require(
            BundledLanguagePluginCatalog.manifests.first { $0.languageSupports?.first?.id == "rust" }
        )
        let content = PluginManagementListContent(plugins: [
            snapshot(pythonManifest),
            snapshot(rustManifest)
        ])

        #expect(content.standalonePlugins.isEmpty)
        #expect(content.languageExtensions.map(\.id) == [pythonManifest.id, rustManifest.id])
    }

    @Test
    func everyBundledLanguagePluginUsesTheLanguageExtensionGroup() {
        let content = PluginManagementListContent(
            plugins: BundledLanguagePluginCatalog.manifests.map(snapshot)
        )

        #expect(content.standalonePlugins.isEmpty)
        #expect(content.languageExtensions.count == BundledLanguagePluginCatalog.manifests.count)
    }

    private func snapshot(_ manifest: PluginManifest) -> PluginManagementSnapshot {
        PluginManagementSnapshot(
            manifest: manifest,
            origin: .bundled,
            installationStatus: .installed,
            isEnabled: false,
            isRequired: false,
            isRunning: false,
            isQuarantined: false,
            isSuppressedBySafeMode: false,
            requiresRestart: false,
            canRollback: false,
            statusMessage: "Disabled"
        )
    }
}
