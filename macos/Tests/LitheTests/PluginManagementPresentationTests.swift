import Testing
import LitheCoreContracts
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

    @Test
    func capabilitiesComeFromTheValidatedDeclaration() throws {
        let descriptor = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(version: PluginVersion(major: 1, minor: 0, patch: 0))
        )

        let capabilities = PluginCapability.capabilities(of: descriptor.pluginManifest, descriptor: descriptor)

        #expect(capabilities == [
            PluginCapability(kind: .language, subject: "fixture", title: "Fixture", detail: .fileTypes([".fixture"])),
            PluginCapability(
                kind: .languageServer, subject: "fixture", title: "Fixture",
                detail: .systemServer(commands: ["fixture-language-server"])
            ),
        ])
    }

    /// Java's run, test, and debug support is Lithe's own JDT integration;
    /// the Features tab says so instead of listing a plugin module.
    @Test
    func javaFeaturesIncludeHostIntegratedCapabilities() throws {
        let java = try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")

        let capabilities = PluginCapability.capabilities(of: java.pluginManifest, descriptor: java)
        let kinds = Set(capabilities.map(\.kind))

        #expect(kinds.isSuperset(of: [.language, .languageServer, .run, .test, .debug]))
        let server = try #require(capabilities.first { $0.kind == .languageServer && $0.subject == "java" })
        if case .runtimeServer(let tool, let packagedRuntime) = server.detail {
            #expect(tool == "java")
            #expect(packagedRuntime)
        } else {
            Issue.record("Expected the Java server to run on the packaged runtime, got \(server.detail)")
        }
        for capability in capabilities where [.run, .test, .debug].contains(capability.kind) {
            #expect(capability.detail == .hostIntegration)
        }
    }

    @Test
    func installedListFiltersByCapabilityStateAndQuery() throws {
        let descriptor = try DeclarativePluginTestSupport.descriptor(
            DeclarativePluginTestSupport.manifestObject(
                id: "io.example.zig-support",
                version: PluginVersion(major: 1, minor: 0, patch: 0),
                signatureRequirement: .unsigned
            )
        )
        let plugin = snapshot(descriptor.pluginManifest, origin: .community).withDeclaration(
            capabilities: PluginCapability.capabilities(of: descriptor.pluginManifest, descriptor: descriptor),
            permissions: descriptor.permissions,
            programs: [],
            previousVersion: nil
        )

        #expect(PluginListFilter.languageServer.matches(plugin, isEnabled: true, hasUpdate: false))
        #expect(!PluginListFilter.buildSystem.matches(plugin, isEnabled: true, hasUpdate: false))
        #expect(!PluginListFilter.ui.matches(plugin, isEnabled: true, hasUpdate: false))
        #expect(PluginListFilter.community.matches(plugin, isEnabled: true, hasUpdate: false))
        #expect(PluginListFilter.update.matches(plugin, isEnabled: true, hasUpdate: true))
        #expect(!PluginListFilter.update.matches(plugin, isEnabled: true, hasUpdate: false))
        #expect(PluginListFilter.disabled.matches(plugin, isEnabled: false, hasUpdate: false))
        #expect(!PluginListFilter.disabled.matches(plugin, isEnabled: true, hasUpdate: false))
        // Capability titles are searchable, not only the plugin's name.
        #expect(PluginListFilter.matches(plugin, query: "fixture"))
        #expect(PluginListFilter.matches(plugin, query: "  EXAMPLE "))
        #expect(!PluginListFilter.matches(plugin, query: "kotlin"))
    }

    @Test
    func everyFilterHasAUniqueSlashToken() {
        let tokens = PluginListFilter.allCases.map(\.token)
        #expect(Set(tokens).count == tokens.count)
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
