import Combine
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Workspace language server preferences")
@MainActor
struct WorkspaceLanguageServerPreferencesTests {
    private let workspace = URL(fileURLWithPath: "/example/lsp-project", isDirectory: true)

    @Test
    func disabledLanguagesSurviveNewPreferenceAndFeatureInstances() throws {
        let suiteName = "lithe-test-lsp-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feature = makeFeature(store: MacUserDefaultsStore(defaults: defaults))
        feature.reloadCatalog(for: workspace)
        #expect(!feature.isDisabled("node"))
        feature.setEnabled(false, providerID: "node")
        feature.setEnabled(false, providerID: "go")
        feature.setEnabled(false, providerID: "rust")
        // A temporarily unavailable plugin must keep its preference so a later
        // catalog update does not silently enable its language server again.
        feature.setEnabled(false, providerID: "example-plugin-language")

        let reopenedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reopened = makeFeature(store: MacUserDefaultsStore(defaults: reopenedDefaults))
        reopened.reloadCatalog(for: workspace.appendingPathComponent("child/..", isDirectory: true))
        #expect(reopened.disabledProviderIDs == ["example-plugin-language", "go", "node", "rust"])

        reopened.reloadCatalog(for: URL(fileURLWithPath: "/example/another-project"))
        #expect(reopened.disabledProviderIDs.isEmpty)
        reopened.setEnabled(false, providerID: "python")
        reopened.reloadCatalog(for: workspace)
        #expect(reopened.disabledProviderIDs == ["example-plugin-language", "go", "node", "rust"])
    }

    @Test(arguments: ["node", "go", "rust"])
    func reenablingPersistsBeforeMatchingDocumentsAreActivated(_ providerID: String) throws {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.reloadCatalog(for: workspace)
        let documentsByProvider = [
            "node": document("main.js"),
            "go": document("main.go"),
            "rust": document("main.rs")
        ]
        for id in documentsByProvider.keys.sorted() {
            feature.setEnabled(false, providerID: id)
        }
        let enabledDocument = try #require(documentsByProvider[providerID])
        let remainingDisabled = Set(documentsByProvider.keys).subtracting([providerID])
        var activatedURLs: [URL] = []
        feature.configure(
            documentsProvider: { documentsByProvider.keys.sorted().compactMap { documentsByProvider[$0] } },
            activateDocument: { document in
                let reopened = makeFeature(store: store)
                reopened.reloadCatalog(for: workspace)
                #expect(!reopened.isDisabled(providerID))
                #expect(reopened.disabledProviderIDs == remainingDisabled)
                activatedURLs.append(document.url)
                return true
            },
            notify: { _ in }
        )

        feature.setEnabled(true, providerID: providerID)

        #expect(activatedURLs == [enabledDocument.url])
        #expect(store.values.values.compactMap { $0 as? [String] } == [remainingDisabled.sorted()])
    }

    @Test
    func runtimeResetAndToolChangesPreserveDisabledLanguages() {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.reloadCatalog(for: workspace)
        feature.setEnabled(false, providerID: "node")

        feature.resetWorkspaceState()
        feature.toolConfigurationDidChange(providerID: "node")
        #expect(feature.isDisabled("node"))

        feature.reloadCatalog(for: nil)
        #expect(feature.disabledProviderIDs.isEmpty)
        feature.reloadCatalog(for: workspace)
        #expect(feature.isDisabled("node"))
    }

    @Test
    func runtimeResetKeepsVisibleProjectUsageButWorkspaceCloseClearsIt() async {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        feature.reloadCatalog(for: workspace)
        let input = feature.projectUsageRequest(workspaceURL: workspace, snapshotID: UUID())
        await feature.projectUsage.load(input, files: [workspace.appendingPathComponent("go.mod")])
        let original = feature.projectUsage.summary(for: input)
        #expect(original?.pluginIDs.contains(OfficialPluginCatalog.goPluginID.rawValue) == true)
        feature.resetWorkspaceState()
        feature.toolConfigurationDidChange(providerID: "go")
        #expect(feature.projectUsage.summary(for: input) == original)
        #expect(feature.projectUsage.state == .ready)
        feature.reloadCatalog(for: nil)
        #expect(feature.projectUsage.summary(for: input) == nil)
        #expect(feature.projectUsage.state == .idle)
    }

    @Test
    func projectUsageInputKeepsTheInventoryPairedWithItsCapturedSnapshot() async {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        let root = FileNode(url: workspace, isDirectory: true, children: [])
        let first = WorkspaceSnapshot(root: root, files: [workspace.appendingPathComponent("go.mod")])
        let captured = feature.projectUsageInput(workspaceURL: workspace, snapshot: first)
        let newer = WorkspaceSnapshot(root: root, files: [workspace.appendingPathComponent("README")])
        let latest = feature.projectUsageInput(workspaceURL: workspace, snapshot: newer)
        #expect(captured.request.snapshotID == first.id)
        #expect(captured.files == first.files)
        #expect(latest.request != captured.request)
        #expect(latest.files == newer.files)
        await feature.projectUsage.load(captured.request, files: captured.files)
        #expect(feature.projectUsage.summary(for: captured.request)?.pluginIDs
            .contains(OfficialPluginCatalog.goPluginID.rawValue) == true)
        feature.projectUsage.reset()
        let empty = feature.projectUsageInput(workspaceURL: nil, snapshot: nil)
        #expect(empty.request.snapshotID == nil)
        #expect(empty.files.isEmpty)
    }

    @Test
    func togglesPublishEvenWithoutARunningLanguageModule() {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        feature.reloadCatalog(for: workspace)
        var changes = 0
        let observation = feature.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        feature.setEnabled(false, providerID: "node")
        #expect(changes == 1)
        feature.setEnabled(true, providerID: "node")
        #expect(changes == 2)
    }

    @Test
    func togglesWithoutAWorkspaceDoNotOverwritePreferences() {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.setEnabled(false, providerID: "node")

        #expect(feature.disabledProviderIDs.isEmpty)
        #expect(store.values.isEmpty)
    }

    @Test
    func disabledLanguageSkipsDocumentStartup() async {
        let store = LanguagePreferencesTestStore()
        MacWorkspaceLanguageServerPreferencesStore(store: store)
            .saveDisabledProviderIDs(["node"], for: workspace)
        let model = makeAppModel(store: store)
        model.languageToolingFeature.reloadCatalog(for: workspace)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)

        #expect(model.activeNotifications.isEmpty)
        #expect(!model.activateLanguageServerIfAvailable(for: document("main.js")))
        #expect(model.languageToolingSessionsIfActive == nil)
        #expect(model.activeNotifications.isEmpty)
        await model.shutdownProjectSession()
    }

    @Test
    func maintenanceSessionsReadSavedPreferencesWithoutDocumentActivation() async throws {
        let store = LanguagePreferencesTestStore()
        let preferences = MacWorkspaceLanguageServerPreferencesStore(store: store)
        preferences.saveDisabledProviderIDs(["python"], for: workspace)
        let model = makeAppModel(store: store, moduleLaunchMode: .normal)
        model.languageToolingFeature.reloadCatalog(for: workspace)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
        do {
            let sessions = try await model.languageSessionsForWorkspaceMaintenance()
            defer { sessions.stopAllLanguageServers() }
            #expect(throws: LanguageToolingSessionError.providerDisabled("Python")) {
                try sessions.startLanguageServer(providerID: "python", rootURL: workspace)
            }
            // A language first disabled after module activation must be observed
            // by the same manager, without recreating or rebinding the module.
            model.setLanguageServerEnabled(false, providerID: "go")
            #expect(throws: LanguageToolingSessionError.providerDisabled("Go")) {
                try sessions.startLanguageServer(providerID: "go", rootURL: workspace)
            }
            #expect(sessions.languageServerOperationIDs.isEmpty)
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }

    @Test
    func disablingALanguageSavesTheChoice() async {
        let store = LanguagePreferencesTestStore()
        let model = makeAppModel(store: store)
        model.languageToolingFeature.reloadCatalog(for: workspace)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)

        model.setLanguageServerEnabled(false, providerID: "node")
        #expect(MacWorkspaceLanguageServerPreferencesStore(store: store)
            .disabledProviderIDs(for: workspace) == ["node"])

        await model.shutdownProjectSession()
    }

    @Test
    func cancelledActivationIsNeitherReportedNorRecordedAsAStartupFailure() throws {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        feature.reloadCatalog(for: workspace)
        let descriptor = try #require(feature.catalog.provider(for: document("main.py").url))
        var notifications: [String] = []
        feature.configure(documentsProvider: { [] }, activateDocument: { _ in false }, notify: { notifications.append($0) })

        feature.markActivationFailed(providerID: descriptor.id, descriptor: descriptor, error: CancellationError())
        #expect(notifications.isEmpty)
        #expect(!feature.shouldRetryCandidate(providerID: descriptor.id))

        feature.markActivationFailed(providerID: descriptor.id, descriptor: descriptor, error: LanguageActivationTestFailure())
        #expect(notifications.count == 1)
        #expect(notifications.first?.hasSuffix(LanguageActivationTestFailure.message) == true)
        #expect(feature.shouldRetryCandidate(providerID: descriptor.id))
    }

    @Test
    func failureOfADisabledServerIsNotReported() throws {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        feature.reloadCatalog(for: workspace)
        let descriptor = try #require(feature.catalog.provider(for: document("main.py").url))
        var notifications: [String] = []
        feature.configure(documentsProvider: { [] }, activateDocument: { _ in false }, notify: { notifications.append($0) })

        // The user turns the server off while its activation is still pending.
        feature.setEnabled(false, providerID: descriptor.id)
        feature.markActivationFailed(providerID: descriptor.id, descriptor: descriptor, error: LanguageActivationTestFailure())

        #expect(notifications.isEmpty)
        #expect(!feature.shouldRetryCandidate(providerID: descriptor.id))
    }

    private func document(_ name: String) -> EditorDocument {
        EditorDocument(url: workspace.appendingPathComponent(name), text: "", modificationDate: nil)
    }

    private func makeFeature(store: any KeyValueStore) -> LanguageToolingFeatureModel {
        let source = LanguagePreferencesTestCatalogSource()
        return LanguageToolingFeatureModel(
            catalogSource: source,
            catalogSnapshot: source.load(workspaceURL: nil),
            preferences: MacWorkspaceLanguageServerPreferencesStore(store: store),
            sessionsProvider: { nil }
        )
    }

    private func makeAppModel(
        store: any KeyValueStore,
        moduleLaunchMode: ModuleLaunchMode = .safeMode
    ) -> AppModel {
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: moduleLaunchMode
        ).services
        return AppModel(settings: settings, services: services)
    }
}

private struct LanguagePreferencesTestCatalogSource: LanguageProviderCatalogSource {
    func load(workspaceURL: URL?) -> LanguageProviderCatalogSnapshot {
        LanguageProviderCatalogSnapshot(
            catalog: .compatibilityFallback,
            schemaVersion: nil,
            origin: .builtin,
            issues: []
        )
    }
}

private final class LanguagePreferencesTestStore: KeyValueStore {
    private(set) var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct LanguageActivationTestFailure: LocalizedError {
    static let message = "Language server executable is unavailable"
    var errorDescription: String? { Self.message }
}
