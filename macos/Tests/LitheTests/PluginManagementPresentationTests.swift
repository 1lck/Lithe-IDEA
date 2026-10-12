import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Plugin management presentation")
struct PluginManagementPresentationTests {
    @Test
    func onlyOfficialPluginsAppearInSettings() throws {
        let php = try DeclarativePluginTestSupport.officialDescriptor("PhpSupport").pluginManifest
        let go = try DeclarativePluginTestSupport.officialDescriptor("GoSupport").pluginManifest
        let pythonManifest = try #require(
            BundledLanguagePluginCatalog.manifests.first { $0.languageSupports?.first?.id == "python" }
        )
        let content = PluginManagementListContent(plugins: [
            snapshot(php),
            snapshot(go),
            snapshot(pythonManifest),
        ])

        #expect(content.plugins.map(\.id) == [php.id, go.id])
        #expect(content.availablePHPManifest == nil)
    }

    @Test
    func cleanInstallShowsPHPInstallEntry() {
        let content = PluginManagementListContent(plugins: [])

        #expect(content.plugins.isEmpty)
        #expect(content.availablePHPManifest?.id == OfficialPluginCatalog.phpPluginID)
    }

    /// Go ships inside Lithe, so PHP stays downloadable next to it.
    @Test
    func bundledGoDoesNotHideThePHPInstallEntry() throws {
        let go = try DeclarativePluginTestSupport.officialDescriptor("GoSupport").pluginManifest
        let content = PluginManagementListContent(plugins: [snapshot(go)])

        #expect(content.plugins.map(\.id) == [OfficialPluginCatalog.goPluginID])
        #expect(content.availablePHPManifest?.id == OfficialPluginCatalog.phpPluginID)
    }

    @MainActor
    @Test
    func settingsOKKeepsFailedPluginChangesForRetry() async {
        let state = SettingsViewState(initialCategory: .plugins)
        let pluginID = OfficialPluginCatalog.phpPluginID
        state.pendingPluginEnabledStates[pluginID] = true

        let shouldCloseAfterFailure = await state.applyPluginChanges { changes in
            #expect(changes == [pluginID: true])
            return []
        }
        #expect(!shouldCloseAfterFailure)
        #expect(state.pendingPluginEnabledStates[pluginID] == true)
        #expect(!state.isApplyingPluginChanges)

        let shouldCloseAfterRetry = await state.applyPluginChanges { _ in [pluginID] }
        #expect(shouldCloseAfterRetry)
        #expect(state.pendingPluginEnabledStates.isEmpty)
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
