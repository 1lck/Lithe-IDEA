import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Plugin management presentation")
struct PluginManagementPresentationTests {
    @Test
    func builtInLanguageSupportIsNotListedAsAPlugin() throws {
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
    }

    /// Community plugins are installed packages, so they are listed even
    /// though the host has no catalog entry for them.
    @Test
    func installedCommunityPluginsAreListed() throws {
        let community = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(
                id: "io.example.zig-support",
                version: PluginVersion(major: 1, minor: 0, patch: 0),
                signatureRequirement: .unsigned
            )
        ).pluginManifest
        let content = PluginManagementListContent(plugins: [snapshot(community, origin: .community)])

        #expect(content.plugins.map(\.id) == [community.id])
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

    private func snapshot(
        _ manifest: PluginManifest,
        origin: PluginInstallationOrigin = .bundled
    ) -> PluginManagementSnapshot {
        PluginManagementSnapshot(
            manifest: manifest,
            origin: origin,
            installationStatus: .installed,
            isEnabled: false,
            isRequired: false,
            isRunning: false,
            isQuarantined: false,
            isSuppressedBySafeMode: false,
            requiresRestart: false,
            canRollback: false,
            statusMessage: "Disabled",
            marketplace: nil
        )
    }
}
