import Combine
import Foundation
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
        #expect(!feature.isDisabled("java"))
        feature.setEnabled(false, providerID: "java")
        feature.setEnabled(false, providerID: "go")
        feature.setEnabled(false, providerID: "rust")
        // A temporarily unavailable plugin must keep its preference so a later
        // catalog update does not silently enable its language server again.
        feature.setEnabled(false, providerID: "example-plugin-language")

        let reopenedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reopened = makeFeature(store: MacUserDefaultsStore(defaults: reopenedDefaults))
        reopened.reloadCatalog(for: workspace.appendingPathComponent("child/..", isDirectory: true))
        #expect(reopened.disabledProviderIDs == ["example-plugin-language", "go", "java", "rust"])

        reopened.reloadCatalog(for: URL(fileURLWithPath: "/example/another-project"))
        #expect(reopened.disabledProviderIDs.isEmpty)
        reopened.setEnabled(false, providerID: "python")
        reopened.reloadCatalog(for: workspace)
        #expect(reopened.disabledProviderIDs == ["example-plugin-language", "go", "java", "rust"])
    }

    @Test(arguments: ["java", "go", "rust"])
    func reenablingPersistsBeforeMatchingDocumentsAreActivated(_ providerID: String) throws {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.reloadCatalog(for: workspace)
        let documentsByProvider = [
            "java": document("Main.java"),
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
        feature.setEnabled(false, providerID: "java")

        feature.resetWorkspaceState()
        feature.toolConfigurationDidChange(providerID: "java")
        #expect(feature.isDisabled("java"))

        feature.reloadCatalog(for: nil)
        #expect(feature.disabledProviderIDs.isEmpty)
        feature.reloadCatalog(for: workspace)
        #expect(feature.isDisabled("java"))
    }

    @Test
    func togglesPublishEvenWithoutARunningLanguageModule() {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        feature.reloadCatalog(for: workspace)
        var changes = 0
        let observation = feature.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        feature.setEnabled(false, providerID: "java")
        #expect(changes == 1)
        feature.setEnabled(true, providerID: "java")
        #expect(changes == 2)
    }

    @Test
    func togglesWithoutAWorkspaceDoNotOverwritePreferences() {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.setEnabled(false, providerID: "java")

        #expect(feature.disabledProviderIDs.isEmpty)
        #expect(store.values.isEmpty)
    }

    @Test
    func disabledJavaSkipsWorkspaceAndDocumentStartup() async {
        let store = LanguagePreferencesTestStore()
        MacWorkspaceLanguageServerPreferencesStore(store: store)
            .saveDisabledProviderIDs(["java"], for: workspace)
        let model = makeAppModel(store: store)
        defer { model.cancelJavaLanguageServerPreparation() }
        // The injected workspace policy allows Java startup. Restoring the saved
        // preference must prevent preparation even when Java files are eligible.
        model.languageToolingFeature.reloadCatalog(for: workspace)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)

        model.prepareJavaLanguageServerForWorkspaceIfNeeded(
            at: workspace,
            files: [workspace.appendingPathComponent("Main.java")]
        )
        #expect(model.javaFeature.languageServerOperationID == nil)
        #expect(model.activeNotifications.isEmpty)
        #expect(!model.activateLanguageServerIfAvailable(for: document("Main.java")))
        #expect(await model.javaNavigationMarkers(for: document("Main.java")) == [])
        #expect(model.javaFeature.languageServerOperationID == nil)
        #expect(model.languageToolingSessionsIfActive == nil)
        #expect(model.activeNotifications.isEmpty)

        // Re-enable on the same model to prove the setup reaches preparation.
        // Cancel before the queued task runs so no JDK or real LSP is needed.
        model.setLanguageServerEnabled(true, providerID: "java")
        guard case .preparing(let owner) = model.javaFeature.languageServerWorkspaceState else {
            Issue.record("Enabling Java should schedule workspace preparation")
            await model.shutdownProjectSession()
            return
        }
        let task = owner.task
        #expect(task != nil)
        model.cancelJavaLanguageServerPreparation()
        await task?.value
        await model.shutdownProjectSession()
    }

    @Test
    func maintenanceSessionsReadSavedPreferencesWithoutDocumentActivation() async throws {
        let store = LanguagePreferencesTestStore()
        let preferences = MacWorkspaceLanguageServerPreferencesStore(store: store)
        preferences.saveDisabledProviderIDs(["java"], for: workspace)
        let model = makeAppModel(store: store, moduleLaunchMode: .normal)
        model.languageToolingFeature.reloadCatalog(for: workspace)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
        do {
            let sessions = try await model.languageSessionsForWorkspaceMaintenance()
            defer { sessions.stopAllLanguageServers() }
            #expect(throws: LanguageToolingSessionError.providerDisabled("Java")) {
                try sessions.startLanguageServer(providerID: "java", rootURL: workspace)
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
    func disablingJavaCancelsPendingPreparationAndSavesTheChoice() async {
        let store = LanguagePreferencesTestStore()
        let model = makeAppModel(store: store)
        model.languageToolingFeature.reloadCatalog(for: workspace)
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
        let owner = model.javaFeature.beginLanguageServerPreparation(
            workspaceURL: workspace,
            operationID: UUID()
        )
        var reachedStartup = false
        JavaLanguageServerPreparationCoordinator().schedule(for: owner) {
            guard !Task.isCancelled else { return }
            reachedStartup = true
        }
        let preparationTask = owner.task
        defer {
            preparationTask?.cancel()
            model.cancelJavaLanguageServerPreparation()
        }

        // The checkbox is turned off before the queued preparation gets its
        // first turn. Cancellation must prevent it from starting a server.
        model.setLanguageServerEnabled(false, providerID: "java")
        #expect(preparationTask?.isCancelled == true)
        #expect(owner.task == nil)
        #expect(model.javaFeature.languageServerOperationID == nil)
        #expect(MacWorkspaceLanguageServerPreferencesStore(store: store)
            .disabledProviderIDs(for: workspace) == ["java"])
        await preparationTask?.value
        #expect(!reachedStartup)

        await model.shutdownProjectSession()
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
            moduleLaunchMode: moduleLaunchMode,
            javaMavenOperations: LanguagePreferencesJavaOperations()
        ).services
        return AppModel(settings: settings, services: services)
    }
}

private struct LanguagePreferencesJavaOperations: JavaMavenOperations {
    func javaWorkspacePolicy(
        at rootURL: URL,
        files: [URL],
        changedFiles: [URL]
    ) -> JavaWorkspacePolicyResult? {
        JavaWorkspacePolicyResult(
            shouldStart: true,
            representativeJavaURL: rootURL.appendingPathComponent("Main.java"),
            changes: []
        )
    }

    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject? { nil }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
    func codeVision(at rootURL: URL, targetPath: String, paths: [String]) -> [JavaCodeVisionValue] { [] }
    func className(source: String, simpleName: String) -> String? { nil }
    func sourceDefinition(source: String, declarationName: String, memberName: String?) -> (line: Int, utf16Column: Int)? { nil }
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
    func scanRunConfigurations(at rootURL: URL, files: [URL], mavenProject: MavenProject?) -> [JavaRunConfiguration] { [] }
    func structure(source: String, declarationSources: [String]) -> JavaStructureResult? { nil }
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
