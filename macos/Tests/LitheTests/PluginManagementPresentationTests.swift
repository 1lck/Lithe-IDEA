import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Plugin management presentation")
struct PluginManagementPresentationTests {
    @Test
    func onlyOfficialPHPPluginAppearsInSettings() throws {
        let phpManifest = try #require(
            OfficialPluginCatalog.manifests.first { $0.id == OfficialPluginCatalog.phpPluginID }
        )
        let goManifest = try #require(
            OfficialPluginCatalog.manifests.first { $0.id != OfficialPluginCatalog.phpPluginID }
        )
        let pythonManifest = try #require(
            BundledLanguagePluginCatalog.manifests.first { $0.languageSupports?.first?.id == "python" }
        )
        let content = PluginManagementListContent(plugins: [
            snapshot(phpManifest),
            snapshot(goManifest),
            snapshot(pythonManifest),
        ])

        #expect(content.plugins.map(\.id) == [phpManifest.id])
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
