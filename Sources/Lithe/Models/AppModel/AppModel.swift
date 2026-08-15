import Combine
import Foundation
import LitheGitModule
import LitheDatabaseModule
import LitheDebugModule
import LitheExecutionModule
import LitheLocalHistoryModule
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import LitheSearchModule
import LitheTerminalModule
import LitheWorkspaceModule
import LitheCoreContracts

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case editor = "Editor"
    case terminal = "Terminal"
    case lsp = "LSP"
    case ai = "AI & Commit"
    case updates = "Updates"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .editor: "textformat"
        case .terminal: "terminal"
        case .lsp: "server.rack"
        case .ai: "wand.and.stars"
        case .updates: "arrow.down.circle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var workspaceURL: URL?
    @Published var selectedSidebar: SidebarDestination = .project {
        didSet {
            guard selectedSidebar == .changes, oldValue != .changes else { return }
            Task { [weak self] in await self?.refreshGit() }
        }
    }
    @Published var isRunVisible = false
    @Published var isTestsVisible = false
    @Published var isSettingsPresented = false
    @Published private(set) var requestedSettingsCategory: SettingsCategory = .general
    @Published var isCloneRepositoryPresented = false
    @Published private(set) var recentProjects: [RecentProject]
    @Published var searchQuery = ""
    @Published var isSearchEverywhereVisible = false
    @Published var searchEverywhereQuery = ""
    @Published var isProjectReplaceVisible = false
    @Published var projectReplaceQuery = ""
    @Published var projectReplaceText = ""
    /// Replace in Project 面板的搜索选项（Preserve Case、文件掩码等）。
    @Published var projectReplaceOptions = ProjectSearchOptions.default
    @Published var selectedProjectReplacementPaths: Set<String> = []
    /// 编辑器当前选中的单行文本，供 Find/Replace in Files 预填查询词。
    @Published var editorSelectedText = ""
    /// 递增令牌：搜索侧栏观察它来把焦点移回输入框。
    @Published var searchSidebarFocusRequest = 0
    @Published var isFindBarVisible = false
    @Published var findBarQuery = ""
    @Published private(set) var findMatchCount = 0
    @Published private(set) var currentFindMatchIndex = 0
    var projectItemEditRequest: ProjectItemEditRequest? {
        get { workspaceFeature.projectItemEditRequest }
        set { workspaceFeature.projectItemEditRequest = newValue }
    }
    var pendingProjectItemDeletion: ProjectItemDeletionRequest? {
        get { workspaceFeature.pendingProjectItemDeletion }
        set { workspaceFeature.pendingProjectItemDeletion = newValue }
    }
    var isPerformingProjectItemOperation: Bool {
        workspaceFeature.isPerformingProjectItemOperation
    }
    @Published var notificationMessage: String?
    @Published var detectedAIConfigurations: [AIConfigurationSnapshot] = []
    @Published var commitMessage = ""
    @Published var amendCommit = false
    @Published private(set) var isGeneratingCommitMessage = false
    @Published private(set) var pendingGeneratedCommitMessage: String?
    @Published var isGitLogVisible = false
    @Published var isTerminalVisible = false
    @Published var isReferencesVisible = false
    @Published var isProblemsVisible = false
    @Published var isMavenVisible = false
    @Published var isDebugVisible = false
    @Published var isImplementationChooserVisible = false
    var languageProviderCatalog: LanguageProviderCatalog { languageToolingFeature.catalog }
    var languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot { languageToolingFeature.catalogSnapshot }
    @Published var languageNavigationProviderID: String?
    @Published var languageNavigationLocations: [LanguageNavigationLocation] = []
    @Published var languageNavigationResultKind: LanguageNavigationResultKind = .definitions
    @Published var isLoadingLanguageNavigation = false
    @Published var editorCaret: EditorCaret?
    @Published var editorNavigationTarget: EditorNavigationTarget?
    var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] {
        javaFeature.javaCodeVisionHints
    }
    var javaInlayHints: [URL: [JavaInlayHint]] {
        javaFeature.javaInlayHints
    }
    @Published var blameVisibleURL: URL?
    @Published var gitLogSearchQuery = ""
    private var doubleShiftDetector: (any ShortcutDetector)?
    private var isProjectSessionActive = true
    private var fileVisibilityRulesObserverID: UUID?
    private var requestProjectOpen: ((URL) -> Void)?
    private var didCloseProject: (() -> Void)?
    private var securityScopedWorkspaceURL: URL?
    let services: AppServices
    let platformUI: any PlatformUI
    let settings: AppSettings
    let runtimeFeature: RuntimeSettingsFeatureModel
    let languageToolingFeature: LanguageToolingFeatureModel
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let workspaceFeature: WorkspaceFeatureModel
    private struct CachedModuleCapability {
        let moduleID: ModuleID
        let value: AnyObject
    }
    private var moduleCapabilities: [ModuleCapabilityID: CachedModuleCapability] = [:]
    private var moduleFeatureObservations: [ModuleID: [AnyCancellable]] = [:]
    var languageCapability: LitheLanguageIntelligenceModule.LanguageIntelligenceCapability? {
        cachedModuleCapability(.languageIntelligence)
    }
    var executionCapability: LitheExecutionModule.ExecutionModuleCapability? {
        cachedModuleCapability(.executionWorkspace)
    }
    var debugCapability: LitheDebugModule.DebugModuleCapability? {
        cachedModuleCapability(.debugWorkspace)
    }
    var searchCapability: LitheSearchModule.SearchModuleCapability? {
        cachedModuleCapability(.searchWorkspace)
    }
    var terminalCapability: LitheTerminalModule.TerminalModuleCapability? {
        cachedModuleCapability(.terminalWorkspace)
    }
    var terminalFeature: TerminalFeatureModel? { terminalCapability?.feature }
    var availableTerminalShells: [String] { terminalFeature?.availableShells ?? [] }

    @MainActor
    func activateTerminalModule() async -> Bool {
        guard terminalCapability == nil else { return true }
        do {
            let value = try await services.moduleRuntime.activateCapability(.terminalWorkspace)
            guard let capability = value as? LitheTerminalModule.TerminalModuleCapability else { return false }
            let feature = capability.feature
            cacheModuleCapability(capability, id: .terminalWorkspace, moduleID: .terminal)
            observeModuleFeature(.terminal, observation: feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return true
        } catch {
            return false
        }
    }
    var historyCapability: LitheLocalHistoryModule.HistoryModuleCapability? {
        cachedModuleCapability(.historyWorkspace)
    }
    var gitCapability: LitheGitModule.GitModuleCapability? {
        cachedModuleCapability(.gitWorkspace)
    }
    let documentFeature: DocumentFeatureModel
    let javaFeature: JavaFeatureModel
    private var activeDatabaseFeature: DatabaseFeatureModel? {
        let capability: LitheDatabaseModule.DatabaseModuleCapability? = cachedModuleCapability(.databaseWorkspace)
        return capability?.feature
    }
    var databaseFeature: DatabaseFeatureModel {
        guard let activeDatabaseFeature else {
            preconditionFailure("Database UI accessed before the Database module was activated.")
        }
        return activeDatabaseFeature
    }
    var isDatabaseModuleActive: Bool { activeDatabaseFeature != nil }
    var moduleSnapshots: [ModuleSnapshot] { services.moduleRuntime.snapshots() }
    var availableSidebarDestinations: [SidebarDestination] {
        SidebarDestination.allCases.filter { destination in
            let moduleID: ModuleID?
            switch destination {
            case .project: moduleID = nil
            case .changes: moduleID = .git
            case .search: moduleID = .search
            case .database: moduleID = .database
            }
            guard let moduleID else { return true }
            return moduleSnapshots.first(where: { $0.manifest.id == moduleID })?.state != .disabled
        }
    }
    var activeModuleContributions: [ModuleContribution] {
        services.moduleRuntime.availableContributions().values.flatMap { $0 }.sorted {
            ($0.placement.rawValue, $0.order, $0.id)
                < ($1.placement.rawValue, $1.order, $1.id)
        }
    }
    var activityBarContributions: [ModuleContribution] {
        activeModuleContributions.filter { $0.placement == .activityBar }
    }
    var workspaceFileOperations: any WorkspaceFileOperations { services.fileOperations }
    func fileExists(at url: URL) -> Bool { services.fileStorage.fileExists(at: url) }
    var languageToolingSessionsIfActive: LanguageToolingSessionManager? {
        languageCapability?.sessions
    }
    var languageServerToolsIfActive: LanguageServerToolService? {
        languageCapability?.tools
    }
    var languageTestServiceIfActive: LanguageTestService? {
        executionCapability?.testService as? LanguageTestService
    }
    var languageDiagnostics: [URL: [LanguageServerDiagnostic]] {
        languageToolingSessionsIfActive?.diagnostics ?? [:]
    }
    var editorDiagnostics: [URL: [EditorDiagnostic]] {
        EditorDiagnostic.fromLanguageServerDiagnostics(languageDiagnostics)
    }
    private var workspaceFeatureObservation: AnyCancellable?
    private var runtimeFeatureObservation: AnyCancellable?
    private var moduleRuntimeObservationID: UUID?

    var detectedCodexConfiguration: CodexConfigurationSnapshot? {
        detectedAIConfigurations.first { $0.source == .codex }
    }

    var detectedClaudeConfiguration: AIConfigurationSnapshot? {
        detectedAIConfigurations.first { $0.source == .claude }
    }

    func showSettings(category: SettingsCategory = .general) {
        requestedSettingsCategory = category
        isSettingsPresented = true
    }

    func chooseLanguageServerExecutable(providerName: String) -> URL? {
        platformUI.chooseFile(
            title: settings.language == .simplifiedChinese
                ? "选择 \(providerName) 语言服务器"
                : "Choose \(providerName) language server",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        )
    }

    func openLanguageServerDownload(_ url: URL) {
        platformUI.open(url)
    }

    func languageServerToolConfigurationDidChange(providerID: String) {
        languageToolingFeature.toolConfigurationDidChange(providerID: providerID)
    }

    func isLanguageServerDisabledInCurrentWorkspace(providerID: String) -> Bool {
        languageToolingFeature.isDisabled(providerID)
    }

    func setLanguageServerEnabled(_ enabled: Bool, providerID: String) {
        if enabled {
            languageToolingFeature.setEnabled(true, providerID: providerID)
        } else {
            languageToolingFeature.setEnabled(false, providerID: providerID)
        }
    }

    var javaLanguageServerJDKPath: String {
        settings.javaLanguageServerJDKPath
    }

    var detectedJavaLanguageServerJDKs: [JavaRuntimeCandidate] {
        runtimeFeature.javaRuntimes
    }

    func selectJavaLanguageServerJDK(_ runtime: JavaRuntimeCandidate) {
        applyJavaLanguageServerJDKPath(runtime.homePath)
    }

    func refreshJavaLanguageServerJDKs() async {
        await runtimeFeature.refreshAvailableRuntimes()
    }

    func chooseJavaLanguageServerJDK() {
        guard let url = platformUI.chooseDirectory(
            title: settings.language == .simplifiedChinese ? "选择 LSP 运行 JDK" : "Choose LSP Runtime JDK",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        ) else { return }
        guard services.projectRuntimeService.configuredJavaExecutableURL(overridePath: url.path) != nil else {
            showNotification(settings.language == .simplifiedChinese
                ? "所选目录不是有效的 JDK Home"
                : "The selected directory is not a valid JDK Home")
            return
        }
        applyJavaLanguageServerJDKPath(url.standardizedFileURL.path)
    }

    private func applyJavaLanguageServerJDKPath(_ path: String) {
        languageToolingFeature.selectJavaJDK(path)
    }

    func disableLanguageServerForCurrentWorkspace(providerID: String) {
        languageToolingFeature.setEnabled(false, providerID: providerID)
    }

    private var documentFeatureObservation: AnyCancellable?
    private var javaFeatureObservation: AnyCancellable?
    private var isObjectWillChangeRelayScheduled = false
    private var languageToolingObservation: AnyCancellable?
    private var recentProjectsStore: RecentProjectsStore { services.recentProjectsStore }
    private var workbenchLayoutStore: WorkbenchLayoutStore { services.workbenchLayoutStore }

    func cachedModuleCapability<Capability: AnyObject>(
        _ id: ModuleCapabilityID,
        as type: Capability.Type = Capability.self
    ) -> Capability? {
        moduleCapabilities[id]?.value as? Capability
    }

    func cacheModuleCapability(
        _ capability: AnyObject,
        id: ModuleCapabilityID,
        moduleID: ModuleID
    ) {
        moduleCapabilities[id] = CachedModuleCapability(moduleID: moduleID, value: capability)
    }

    func clearModuleBindings(for moduleID: ModuleID) {
        moduleFeatureObservations[moduleID] = nil
        moduleCapabilities = moduleCapabilities.filter { $0.value.moduleID != moduleID }
        for ownership in services.pluginCatalog.languageSupports.values {
            let support = ownership.declaration
            if support.languageServerModuleID == moduleID {
                languageToolingSessionsIfActive?.unregisterLanguageServerExtension(
                    languageID: support.id
                )
            }
            if support.executionModuleID == moduleID {
                runFeatureIfActive?.unregisterLanguageRunExtension(languageID: support.id)
            }
            if support.testingModuleID == moduleID {
                languageTestServiceIfActive?.unregisterLanguageTestExtension(languageID: support.id)
            }
        }
    }

    func observeModuleFeature(
        _ moduleID: ModuleID,
        observation: AnyCancellable
    ) {
        moduleFeatureObservations[moduleID, default: []].append(observation)
    }

    func scheduleObjectWillChangeRelay() {
        guard !isObjectWillChangeRelayScheduled else { return }
        isObjectWillChangeRelayScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isObjectWillChangeRelayScheduled = false
            self.objectWillChange.send()
        }
    }

    init(settings: AppSettings, services: AppServices) {
        self.settings = settings
        self.services = services
        platformUI = services.platformUI
        workspaceFeature = WorkspaceFeatureModel(
            operations: services.workspaceOperations,
            fileOperations: services.fileOperations,
            gitWatchContextProvider: services.gitWatchContextProvider,
            directoryWatcherFactory: services.directoryWatcherFactory,
            workspaceSessionStore: services.workspaceSessionStore
        )
        Task { @MainActor [workspaceFeature, moduleRuntime = services.moduleRuntime] in
            guard let capability = try? await moduleRuntime.activateCapability(.workspaceFoundation),
                  let capability = capability as? LitheWorkspaceModule.WorkspaceFoundationCapability else { return }
            capability.attach(workspaceProjection: workspaceFeature)
        }
        runtimeFeature = RuntimeSettingsFeatureModel(service: services.projectRuntimeService)
        languageToolingFeature = LanguageToolingFeatureModel(
            catalogSource: services.languageProviderCatalogSource,
            catalogSnapshot: services.languageProviderCatalogSnapshot,
            sessionsProvider: { nil },
            runtimeFeature: runtimeFeature,
            settings: settings,
            projectRuntimeService: services.projectRuntimeService
        )
        debugLaunchConfigurationResolver = services.debugLaunchConfigurationResolver
        documentFeature = DocumentFeatureModel(
            operations: services.workspaceOperations,
            fileOperations: services.fileOperations,
            fileStorage: services.fileStorage,
            binaryFileViewerRegistry: services.binaryFileViewerRegistry
        )
        javaFeature = JavaFeatureModel(
            operations: services.javaMavenOperations,
            workspaceOperations: services.workspaceOperations
        )
        recentProjects = services.recentProjectsStore.load()
        languageToolingFeature.configureSessions { [weak self] in
            self?.languageToolingSessionsIfActive
        }
        moduleRuntimeObservationID = services.moduleRuntime.observeEvents { [weak self] event in
            guard let self else { return }
            if event.name == "module.sleeping" || event.name == "module.shutdown" {
                if event.source == .database, selectedSidebar == .database {
                    selectedSidebar = .project
                }
                clearModuleBindings(for: event.source)
            }
            if event.name == ModuleEvent.stateChangedName
                || event.name == "module.sleeping"
                || event.name == "module.shutdown" {
                scheduleObjectWillChangeRelay()
            }
        }
        workspaceFeatureObservation = workspaceFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        runtimeFeatureObservation = runtimeFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        workspaceFeature.configureProjection(
            documentsProvider: { [weak self] in
                self?.openDocuments.map { WorkspaceDocumentState(url: $0.url, isDirty: $0.isDirty) } ?? []
            },
            activeDocumentProvider: { [weak self] in
                self?.activeDocument.map { WorkspaceDocumentState(url: $0.url, isDirty: $0.isDirty) }
            },
            selectedSidebarProvider: { [weak self] in self?.selectedSidebar.rawValue ?? SidebarDestination.project.rawValue },
            setSelectedSidebar: { [weak self] rawValue in
                self?.selectedSidebar = SidebarDestination(rawValue: rawValue) ?? .project
            },
            restoreSession: { [weak self] session, availableFiles in
                guard let self else { return }
                let availablePaths = Set(availableFiles.map { $0.standardizedFileURL.path })
                self.selectedSidebar = SidebarDestination(rawValue: session.selectedSidebar) ?? .project
                let paths = session.openPaths.filter { availablePaths.contains($0) }
                await withTaskGroup(of: Void.self) { group in
                    for path in paths {
                        group.addTask { [weak self] in
                            await self?.documentFeature.openFileAsync(
                                URL(fileURLWithPath: path),
                                isReadOnly: false,
                                displayPath: nil,
                                activateWhenReady: false
                            )
                        }
                    }
                }
                self.documentFeature.reorderDocuments(orderedPaths: paths)
                if let activePath = session.activePath,
                   let document = self.openDocuments.first(where: {
                       $0.url.standardizedFileURL.path == activePath
                   }) {
                    self.activeDocumentID = document.id
                } else {
                    self.activeDocumentID = self.openDocuments.last?.id
                }
            },
            openFile: { [weak self] url in self?.openFile(url) },
            notify: { [weak self] message in self?.showNotification(message) },
            recordHistory: { [weak self] url, reason in
                guard let feature = await self?.activateHistoryModule() else { return }
                await feature.recordHistory(containedIn: url, reason: reason)
            },
            relocateHistory: { [weak self] source, destination in
                guard let feature = await self?.activateHistoryModule() else { return }
                await feature.relocateHistory(from: source, to: destination)
            },
            relocateOpenDocuments: { [weak self] source, destination in
                self?.documentFeature.relocateOpenDocuments(from: source, to: destination)
            },
            closeDocuments: { [weak self] url in
                self?.documentFeature.closeDocuments(containedIn: url)
            },
            processExternalChanges: { [weak self] paths in
                guard let self else { return false }
                let conflict = self.documentFeature.processExternalChanges(paths)
                self.withHistoryModule { $0.recordExternalChanges(paths) }
                return conflict
            },
            reloadProjectServices: { [weak self] in
                guard let self, let workspaceURL = self.workspaceURL else { return }
                await self.loadProjectServices(at: workspaceURL, files: self.projectFiles)
            },
            refreshGit: { [weak self] in
                guard let feature = self?.gitFeatureIfActive else { return }
                await feature.refreshGit()
            },
            updateHistoryVisibilityRules: { [weak self] rules in
                guard let feature = await self?.activateHistoryModule() else { return }
                await feature.updateVisibilityRules(rules.localHistoryRules)
            },
            onSnapshotLoaded: { [weak self] snapshot, isInitialLoad in
                guard let self, let workspaceURL = self.workspaceURL else { return }
                // WorkspaceFeatureModel requests the single Git refresh after this callback.
                await self.loadProjectServices(at: workspaceURL, files: snapshot.files)
                if isInitialLoad {
                    self.projectHistoryFeatureIfActive?.seed(files: snapshot.files)
                }
            },
            warmSearchIndex: { [weak self] workspaceURL, rules in
                self?.searchFeatureIfActive?.warmIndex(at: workspaceURL, visibilityRules: rules.searchRules)
            },
            updateSearchIndex: { [weak self] workspaceURL, paths, rules in
                await self?.searchFeatureIfActive?.updateIndex(
                    at: workspaceURL,
                    changedPaths: paths,
                    visibilityRules: rules.searchRules
                )
            },
            invalidateSearchIndex: { [weak self] workspaceURL, rules in
                self?.searchFeatureIfActive?.invalidateIndex(at: workspaceURL, visibilityRules: rules.searchRules)
            }
        )
        languageToolingFeature.configure(
            documentsProvider: { [weak self] in self?.openDocuments ?? [] },
            workspaceProvider: { [weak self] in self?.workspaceURL },
            activateDocument: { [weak self] document in
                self?.activateLanguageServerIfAvailable(for: document) ?? false
            },
            notify: { [weak self] message in self?.showNotification(message) }
        )
        documentFeature.configure(
            workspaceURLProvider: { [weak self] in self?.workspaceURL },
            autoSaveEnabledProvider: { [weak self] in self?.settings.autoSave ?? false },
            autoSaveDelayProvider: { [weak self] in self?.settings.autoSaveDelay ?? 0 },
            notify: { [weak self] message in self?.showNotification(message) },
            onDocumentOpened: { [weak self] document in
                guard let self else { return }
                self.activateLanguageServerIfAvailable(for: document)
                guard self.javaFeature.handles(fileURL: document.url) else { return }
                Task { await self.refreshCodeVision(for: document.url) }
                self.javaFeature.refreshInlayHints(
                    for: document,
                    projectFiles: self.projectFiles,
                    workspaceRoot: self.workspaceURL
                )
            },
            onDocumentChanged: { [weak self] document in
                self?.handleDocumentChanged(document)
            },
            onDocumentClosed: { [weak self] document in
                self?.handleDocumentClosed(document)
            },
            onRecordSave: { [weak self] document, previousText in
                self?.recordSave(document, previousText: previousText)
            },
            onRecordDiscard: { [weak self] document in
                self?.recordDiscardedEditorText(document)
            },
            onRecordExternalChanges: { [weak self] paths in
                self?.withHistoryModule { $0.recordExternalChanges(paths) }
            },
            onDocumentCollectionChanged: { [weak self] in
                self?.workspaceFeature.scheduleWorkspaceSessionPersistence()
            },
            onProjectCloseReady: { [weak self] in
                self?.performCloseProject()
            }
        )
        documentFeatureObservation = documentFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        javaFeature.configure(
            documentProvider: { [weak self] in self?.activeDocument },
            caretProvider: { [weak self] in self?.editorCaret },
            notify: { [weak self] message in self?.showNotification(message) },
            loadBlame: { [weak self] fileURL in
                guard let self else { return [] }
                guard let feature = await self.activateGitModule() else { return [] }
                return await feature.loadBlame(for: fileURL)
            }
        )
        javaFeatureObservation = javaFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        fileVisibilityRulesObserverID = settings.addFileVisibilityRulesObserver { [weak self] in
            guard let self else { return }
            self.workspaceFeature.updateVisibilityRules(self.settings.fileVisibilityRules)
        }
        detectedAIConfigurations = loadAIConfigurations()
        let activeProviderHasAPIKey = settings.activeCommitMessageProvider
            .flatMap { services.credentialResolver.readAPIKey(for: $0) }
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let activeProviderSource = settings.activeCommitMessageProvider?.credentialSource.configurationSource
        let needsConfigurationImport = activeProviderSource != nil && !activeProviderHasAPIKey
        let codexConfiguration = detectedAIConfigurations.first { $0.source == .codex }
        let shouldImportCodex = !settings.commitMessageAI.codexImportCompleted && codexConfiguration != nil
        let configurationToImport = activeProviderSource.flatMap { source in
            detectedAIConfigurations.first { $0.source == source }
        }
        if let configuration = (needsConfigurationImport ? configurationToImport : nil) ?? (shouldImportCodex ? codexConfiguration : nil) {
            let provider = settings.importAIConfiguration(configuration)
            try? services.secureStore.delete(key: provider.apiKeyIdentifier)
        } else if settings.commitMessageAI.providers.isEmpty,
                  let configuration = detectedAIConfigurations.first {
            let provider = settings.importAIConfiguration(configuration)
            try? services.secureStore.delete(key: provider.apiKeyIdentifier)
        }
        languageServerToolsIfActive?.onCandidatesChanged = { [weak self] providerID in
            guard let self,
                  self.languageToolingFeature.shouldRetryCandidate(providerID: providerID),
                  let document = self.activeDocument,
                  self.languageProviderCatalog.provider(for: document.url)?.id == providerID else {
                return
            }
            _ = self.activateLanguageServerIfAvailable(for: document)
        }
        doubleShiftDetector = services.shortcutDetectorFactory.make { [weak self] in
            self?.toggleSearchEverywhere()
        }
        doubleShiftDetector?.start()
    }

    func activateDatabaseModule() async {
        do {
            let value = try await services.moduleRuntime.activateCapability(.databaseWorkspace)
            guard let capability = value as? LitheDatabaseModule.DatabaseModuleCapability else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .database,
                    capability: .databaseWorkspace
                )
            }
            let feature = capability.feature
            cacheModuleCapability(capability, id: .databaseWorkspace, moduleID: .database)
            observeModuleFeature(.database, observation: feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            selectedSidebar = .database
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func sleepDatabaseModule() async {
        do {
            try await services.moduleRuntime.sleep(.database)
            clearModuleBindings(for: .database)
            if selectedSidebar == .database { selectedSidebar = .project }
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    deinit {
        doubleShiftDetector?.stop()
    }

    func configureProjectSession(
        requestOpen: @escaping (URL) -> Void,
        didClose: @escaping () -> Void
    ) {
        requestProjectOpen = requestOpen
        didCloseProject = didClose
    }

    func setProjectSessionActive(_ isActive: Bool) {
        guard isProjectSessionActive != isActive else { return }
        isProjectSessionActive = isActive
        if isActive {
            doubleShiftDetector?.start()
        } else {
            doubleShiftDetector?.stop()
            isSearchEverywhereVisible = false
        }
    }

    func shutdownProjectSession() {
        doubleShiftDetector?.stop()
        Task { [weak self] in
            await self?.services.moduleRuntime.shutdownAll()
        }
        languageToolingSessionsIfActive?.stopAll()
        languageTestServiceIfActive?.stop()
        stopTerminalSessions()
        stopAccessingWorkspace()
        if let fileVisibilityRulesObserverID {
            settings.removeFileVisibilityRulesObserver(fileVisibilityRulesObserverID)
            self.fileVisibilityRulesObserverID = nil
        }
    }

    private func reloadJavaRuntimeServices() {
        debugFeatureIfActive?.stop()
        mavenFeatureIfActive?.stop()
        languageToolingSessionsIfActive?.stopLanguageServer(providerID: "java")
        javaFeature.stop()
        if let workspaceURL {
            if let document = activeDocument,
               document.url.pathExtension.lowercased() == "java" {
                activateLanguageServerIfAvailable(for: document)
            }
            Task { [weak self] in
                guard let self else { return }
                await self.loadProjectServices(at: workspaceURL, files: self.projectFiles)
            }
        }
    }

    /// Loads build-system and run state at the workspace boundary. The generic
    /// run lifecycle is intentionally not owned by JavaFeatureModel.
    func loadProjectServices(at workspaceURL: URL, files: [URL]) async {
        guard let execution = await activateExecutionModule() else { return }
        execution.tests.discover(workspaceURL: workspaceURL, files: files)
        await execution.projectDevelopment.loadProject(at: workspaceURL, files: files)
    }

    var projectName: String {
        workspaceURL?.lastPathComponent ?? "Lithe"
    }

    var languageServerStatusMessage: String {
        let usesChinese = settings.language == .simplifiedChinese
        guard let document = activeDocument,
              let descriptor = languageProviderCatalog.provider(for: document.url),
              descriptor.capabilities.contains(.languageServer) else {
            return usesChinese ? "打开一个受支持的源码文件" : "Open a supported source file"
        }

        let status = LSPControlCenterPresenter.serverStatus(
            isDisabled: languageToolingFeature.isDisabled(descriptor.id),
            sessionState: languageToolingSessionsIfActive?.languageServerStates[descriptor.id]
        )
        switch status {
        case .starting:
            return usesChinese
                ? "正在启动 \(descriptor.displayName) LSP 进程"
                : "Starting the \(descriptor.displayName) LSP process"
        case .initializing:
            return usesChinese
                ? "正在初始化 \(descriptor.displayName) LSP"
                : "Initializing \(descriptor.displayName) LSP"
        case .active:
            return usesChinese
                ? "\(descriptor.displayName) 语言服务器已就绪"
                : "\(descriptor.displayName) language server ready"
        case .stopping:
            return usesChinese
                ? "正在停止 \(descriptor.displayName) LSP"
                : "Stopping \(descriptor.displayName) LSP"
        case .stopped:
            return usesChinese
                ? "\(descriptor.displayName) 已由 catalog 声明，但当前没有运行中的 LSP 会话"
                : "\(descriptor.displayName) is declared by the catalog, but no LSP session is running"
        case .disabled:
            return usesChinese
                ? "\(descriptor.displayName) LSP 已在当前工作区禁用"
                : "\(descriptor.displayName) LSP is disabled in this workspace"
        case .error:
            return usesChinese
                ? "\(descriptor.displayName) LSP 异常退出"
                : "\(descriptor.displayName) LSP exited unexpectedly"
        }
    }

    func restartLanguageServers() {
        languageToolingSessionsIfActive?.stopAllLanguageServers()
        languageToolingFeature.resetWorkspaceState()
        let didStart = activateCurrentDocumentLanguageServerIfAvailable()
        showNotification(
            didStart
                ? (settings.language == .simplifiedChinese ? "语言服务器已启动" : "Language server started")
                : (settings.language == .simplifiedChinese ? "当前没有运行中的 LSP 会话" : "No LSP session is running")
        )
    }

    func clearLanguageServerDiagnostics() {
        languageToolingSessionsIfActive?.clearDiagnostics()
        showNotification(settings.language == .simplifiedChinese ? "语言服务器诊断已清空" : "Language server diagnostics cleared")
    }

    func javaStructure(source: String, declarationSources: [String] = []) -> JavaStructureResult? {
        javaFeature.structure(source: source, declarationSources: declarationSources)
    }

    var activeDocument: EditorDocument? {
        documentFeature.activeDocument
    }

    func renderMarkdown(_ source: String) async throws -> MarkdownRenderedContent {
        try await services.markdownRenderer.render(source)
    }

    func markdownImageFromClipboard() -> MarkdownImageSource? {
        platformUI.markdownImageFromClipboard()
    }

    func importMarkdownImage(
        _ source: MarkdownImageSource,
        for document: EditorDocument
    ) async throws -> MarkdownImageImportResult {
        guard !document.isReadOnly else { throw MarkdownImageImportError.readOnlyDocument }
        guard ["md", "markdown"].contains(document.url.pathExtension.lowercased()) else {
            throw MarkdownImageImportError.notMarkdownDocument
        }
        guard let workspaceURL else { throw MarkdownImageImportError.unavailableWorkspace }
        return try await services.markdownImageImporter.importImage(
            source,
            forDocumentAt: document.url,
            workspaceRoot: workspaceURL
        )
    }

    var currentGitReference: GitReference? {
        gitReferences.first(where: \.isCurrent)
    }

    func chooseProject() {
        chooseProject(title: "Open a project", prompt: "Open")
    }

    func chooseProject(title: String, prompt: String) {
        guard let url = platformUI.chooseDirectory(title: title, prompt: prompt) else { return }
        openProject(url)
    }

    func showCloneRepository() {
        isCloneRepositoryPresented = true
    }

    func cloneRepository(remote: String, destination: URL) async -> String? {
        guard let gitFeature = await activateGitModule() else { return "Git module is disabled" }
        let result = await gitFeature.cloneRepository(
            remote: remote,
            destination: destination,
            destinationExists: { [workspaceFeature] url in workspaceFeature.fileExists(at: url) }
        )
        guard result.succeeded else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Git operation failed" : message
        }

        isCloneRepositoryPresented = false
        showNotification("Cloned \(destination.lastPathComponent)")
        openProject(destination)
        return nil
    }

    func openProject(_ url: URL) {
        if let requestProjectOpen {
            requestProjectOpen(url.standardizedFileURL)
            return
        }
        openProjectDirectly(url)
    }

    func openProjectDirectly(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        Task { [weak self] in
            guard let self else { return }
            await self.services.moduleRuntime.shutdownAll()
            await MainActor.run {
                self.clearModuleBindings(for: .database)
            }
        }
        if let previousWorkspaceURL = workspaceURL {
            workspaceFeature.persistWorkspaceSession(for: previousWorkspaceURL)
        }
        // A workspace root is a hard language-server ownership boundary. Stop
        // every provider session before replacing the catalog or clearing the
        // document projection so no old-root documents, diagnostics, or
        // responses can survive into the next workspace.
        languageToolingSessionsIfActive?.stopAll()
        reloadLanguageProviderCatalog(for: normalizedURL)
        stopTerminalSessions()
        languageTestServiceIfActive?.reset()
        languageToolingFeature.resetWorkspaceState()
        runtimeFeature.openProject(at: normalizedURL)
        mavenFeatureIfActive?.reset()
        runFeatureIfActive?.reset()
        debugFeatureIfActive?.reset()
        genericDebugFeatureIfActive?.reset()
        clearLanguageNavigationProjection()
        javaFeature.stop()
        workspaceFeature.reset()
        searchFeatureIfActive?.reset()
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isTestsVisible = false
        isDebugVisible = false
        editorCaret = nil
        editorNavigationTarget = nil
        blameVisibleURL = nil
        gitFeatureIfActive?.reset()
        documentFeature.reset()
        gitLogSearchQuery = ""
        projectHistoryFeatureIfActive?.reset()
        workspaceURL = normalizedURL
        let visibilityRules = settings.fileVisibilityRules
        workspaceFeature.beginWorkspace(at: normalizedURL, visibilityRules: visibilityRules)
        selectedSidebar = .project
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        recentProjects = recentProjectsStore.record(normalizedURL, in: recentProjects)

        Task {
            _ = await workspaceFeature.rebuild(
                at: normalizedURL,
                rules: visibilityRules,
                isCurrent: { [weak self] in self?.workspaceURL == normalizedURL }
            )
        }
    }

    func resumeGitObservationAfterActivation() async {
        await workspaceFeature.resumeObservationAfterActivation()
    }

    func closeProject() {
        guard workspaceURL != nil else { return }
        guard documentFeature.beginProjectClose() else {
            performCloseProject()
            return
        }
    }

    private func performCloseProject() {
        Task { [weak self] in
            guard let self else { return }
            await self.services.moduleRuntime.shutdownAll()
            await MainActor.run {
                self.clearModuleBindings(for: .database)
            }
        }
        if let workspaceURL {
            workspaceFeature.persistWorkspaceSession(for: workspaceURL)
        }
        stopAccessingWorkspace()
        workspaceURL = nil
        reloadLanguageProviderCatalog(for: nil)
        selectedSidebar = .project
        workspaceFeature.reset()
        documentFeature.reset()
        searchFeatureIfActive?.reset()
        searchQuery = ""
        isSearchEverywhereVisible = false
        searchEverywhereQuery = ""
        isProjectReplaceVisible = false
        projectReplaceQuery = ""
        projectReplaceText = ""
        selectedProjectReplacementPaths = []
        isFindBarVisible = false
        findBarQuery = ""
        findMatchCount = 0
        currentFindMatchIndex = 0
        projectHistoryFeatureIfActive?.reset()
        workspaceFeature.reset()
        gitFeatureIfActive?.reset()
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isTestsVisible = false
        isDebugVisible = false
        stopTerminalSessions()
        languageToolingSessionsIfActive?.stopAll()
        languageTestServiceIfActive?.reset()
        runtimeFeature.closeProject()
        mavenFeatureIfActive?.reset()
        runFeatureIfActive?.reset()
        debugFeatureIfActive?.reset()
        genericDebugFeatureIfActive?.reset()
        javaFeature.stop()
        editorCaret = nil
        editorNavigationTarget = nil
        blameVisibleURL = nil
        gitLogSearchQuery = ""
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        refreshRecentProjects()
        didCloseProject?()
    }

    private func stopAccessingWorkspace() {
        guard let securityScopedWorkspaceURL else { return }
        platformUI.stopAccessingProject(securityScopedWorkspaceURL)
        self.securityScopedWorkspaceURL = nil
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects = recentProjectsStore.remove(project, from: recentProjects)
    }

    func refreshRecentProjects() {
        recentProjects = recentProjectsStore.load()
    }

    func loadWorkbenchLayout(for workspaceURL: URL) -> WorkbenchLayout {
        workbenchLayoutStore.load(for: workspaceURL)
    }

    func saveWorkbenchLayout(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        workbenchLayoutStore.save(layout, for: workspaceURL)
    }

    private func reloadLanguageProviderCatalog(for workspaceURL: URL?) {
        languageToolingFeature.reloadCatalog(for: workspaceURL)
    }

    func openFile(
        _ url: URL,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        selectedChange = nil
        closeBranchComparison()
        documentFeature.openFile(url, isReadOnly: isReadOnly, displayPath: displayPath)
    }

    func javaIconKind(for url: URL) async -> LitheIconKind? {
        await JavaFileIconResolver.resolve(for: url, storage: services.fileStorage)
    }

    func refreshWorkspace() async {
        await workspaceFeature.refreshCurrent()
    }

    func requestCreateFile(in directory: URL) {
        workspaceFeature.requestCreateFile(in: directory)
    }

    func requestCreateDirectory(in directory: URL) {
        workspaceFeature.requestCreateDirectory(in: directory)
    }

    func requestRenameProjectItem(at url: URL) {
        workspaceFeature.requestRenameProjectItem(at: url)
    }

    func cancelProjectItemEdit() {
        workspaceFeature.cancelProjectItemEdit()
    }

    func performProjectItemEdit(named rawName: String) async {
        await workspaceFeature.performProjectItemEdit(named: rawName)
    }

    func duplicateProjectItem(at sourceURL: URL) async {
        await workspaceFeature.duplicateProjectItem(at: sourceURL)
    }

    func requestDeleteProjectItem(at url: URL, isDirectory: Bool) {
        workspaceFeature.requestDeleteProjectItem(at: url, isDirectory: isDirectory)
    }

    func cancelProjectItemDeletion() {
        workspaceFeature.cancelProjectItemDeletion()
    }

    func confirmProjectItemDeletion() async {
        await workspaceFeature.confirmProjectItemDeletion()
    }

    func revealProjectItemInFinder(_ url: URL) {
        platformUI.revealInFileBrowser(url)
    }

    func copyProjectItemPath(_ url: URL, relative: Bool) {
        let relativeValue = relativePath(for: url)
        let value = relative ? (relativeValue.isEmpty ? "." : relativeValue) : url.path
        platformUI.copyToClipboard(value)
        showNotification(relative ? "Copied relative path" : "Copied path")
    }

    func showLocalHistory(for fileURL: URL) {
        withHistoryModule { $0.showLocalHistory(for: fileURL) }
    }

    func showProjectLocalHistory() {
        withHistoryModule { $0.showProjectLocalHistory() }
    }

    func selectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        projectHistoryFeatureIfActive?.selectLocalHistoryEntry(entry)
    }

    func selectProjectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        projectHistoryFeatureIfActive?.selectProjectLocalHistoryEntry(entry)
    }

    func refreshLocalHistory() async {
        guard let feature = await activateHistoryModule() else { return }
        await feature.refreshLocalHistory()
    }

    func refreshProjectLocalHistory() async {
        guard let feature = await activateHistoryModule() else { return }
        await feature.refreshProjectLocalHistory()
    }

    func restoreSelectedLocalHistoryEntry() async {
        guard let feature = await activateHistoryModule(),
              let restoration = await feature.restoreSelectedLocalHistoryEntry() else {
            showNotification("Could not restore local history")
            return
        }
        if let documentID = restoration.documentID {
            try? openDocuments.first(where: { $0.id == documentID })?.reloadFromDisk()
            activeDocumentID = documentID
        } else {
            openFile(restoration.url)
        }
        showNotification("Restored \(restoration.url.lastPathComponent)")
        await refreshWorkspace()
        await feature.refreshLocalHistory()
    }

    func restoreSelectedProjectLocalHistoryEntry() async {
        guard let feature = await activateHistoryModule(),
              let restoration = await feature.restoreSelectedProjectLocalHistoryEntry() else {
            showNotification("Could not restore project history")
            return
        }
        if let documentID = restoration.documentID {
            try? openDocuments.first(where: { $0.id == documentID })?.reloadFromDisk()
            activeDocumentID = documentID
        }
        showNotification("Restored \(restoration.url.lastPathComponent)")
        await refreshWorkspace()
        await feature.refreshProjectLocalHistory()
    }

    func requestCloseDocument(_ document: EditorDocument) {
        documentFeature.requestCloseDocument(document)
    }

    /// 关闭一组编辑器标签,先关闭未修改的标签,修改过的标签逐个经过现有保存确认。
    /// preferredDocumentID 用于“关闭其他标签”这类操作,保证右键目标标签仍保持激活。
    func requestCloseDocuments(
        _ documents: [EditorDocument],
        preferredDocumentID: UUID? = nil
    ) {
        documentFeature.requestCloseDocuments(documents, preferredDocumentID: preferredDocumentID)
    }

    func closePendingDocument(discardingChanges: Bool) {
        documentFeature.closePendingDocument(discardingChanges: discardingChanges)
    }

    func cancelPendingClose() {
        documentFeature.cancelPendingClose()
    }

    var hasUnsavedDocuments: Bool {
        documentFeature.hasUnsavedDocuments
    }

    @discardableResult
    func saveAllDocuments() -> Bool {
        documentFeature.saveAllDocuments()
    }

    func saveActiveDocument() {
        documentFeature.saveActiveDocument()
    }

    func saveDocument(_ document: EditorDocument) throws {
        try documentFeature.save(document)
    }

    func workspaceRelativePath(for url: URL, root: URL) -> String? {
        let normalizedRoot = root.standardizedFileURL.path
        let normalizedPath = url.standardizedFileURL.path
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else { return nil }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }

    func documentDidChange(_ document: EditorDocument) {
        documentFeature.documentDidChange(document)
    }

    private func handleDocumentChanged(_ document: EditorDocument) {
        activateLanguageServerIfAvailable(for: document)
        Task { @MainActor [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, let document else { return }
            guard self.javaFeature.handles(fileURL: document.url) else { return }
            await self.refreshCodeVision(for: document.url)
            self.refreshJavaInlayHints(for: document)
        }
    }

    private func handleDocumentClosed(_ document: EditorDocument) {
        languageToolingSessionsIfActive?.closeDocument(document.url)
        if javaFeature.handles(fileURL: document.url) {
            javaFeature.close(document)
        }
    }

    @discardableResult
    func activateCurrentDocumentLanguageServerIfAvailable() -> Bool {
        guard let activeDocument else { return false }
        return activateLanguageServerIfAvailable(for: activeDocument)
    }

    @discardableResult
    private func activateLanguageServerIfAvailable(for document: EditorDocument) -> Bool {
        guard let workspaceURL,
              let descriptor = languageProviderCatalog.provider(for: document.url) else { return false }
        if let ownership = services.pluginCatalog.languageSupport(for: document.url),
           ownership.declaration.languageServerModuleID != nil {
            let support = ownership.declaration
            let capabilityID = ModuleCapabilityID.languageServerExtension(support.id)
            if services.moduleRuntime.capability(capabilityID) == nil {
                Task { [weak self, weak document] in
                    guard let self, let document else { return }
                    do {
                        _ = try await self.services.moduleRuntime.activateCapability(capabilityID)
                        _ = self.activateLanguageServerIfAvailable(for: document)
                    } catch {
                        self.languageToolingFeature.markActivationFailed(
                            providerID: descriptor.id,
                            descriptor: descriptor,
                            error: error
                        )
                    }
                }
                return false
            }
            if let provider = services.moduleRuntime.capability(capabilityID)
                    as? any LanguageServerExtensionProviding,
               let sessions = languageToolingSessionsIfActive,
               !sessions.registerLanguageServerExtension(provider, support: support) {
                languageToolingFeature.markActivationFailed(
                    providerID: descriptor.id,
                    descriptor: descriptor,
                    error: LanguageExtensionRegistrationError.invalidLanguageServerProvider(
                        support.displayName
                    )
                )
                return false
            }
        }
        if let snapshot = try? services.moduleRuntime.snapshot(for: .languageIntelligence),
           snapshot.state != .active,
           snapshot.state != .idle {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let value = try await self.services.moduleRuntime.activateCapability(.languageIntelligence)
                    guard let capability = value as? LitheLanguageIntelligenceModule.LanguageIntelligenceCapability else { return }
                    self.cacheModuleCapability(capability, id: .languageIntelligence, moduleID: .languageIntelligence)
                    self.observeModuleFeature(.languageIntelligence, observation: capability.sessions.objectWillChange.sink { [weak self] _ in
                        self?.scheduleObjectWillChangeRelay()
                    })
                    capability.tools.onCandidatesChanged = { [weak self] providerID in
                        guard let self,
                              self.languageToolingFeature.shouldRetryCandidate(providerID: providerID),
                              let document = self.activeDocument,
                              self.languageProviderCatalog.provider(for: document.url)?.id == providerID else { return }
                        _ = self.activateLanguageServerIfAvailable(for: document)
                    }
                    _ = self.activateLanguageServerIfAvailable(for: document)
                } catch {
                    self.languageToolingFeature.markActivationFailed(
                        providerID: descriptor.id,
                        descriptor: descriptor,
                        error: error
                    )
                }
            }
            return false
        }
        guard !languageToolingFeature.isDisabled(descriptor.id) else {
            languageToolingSessionsIfActive?.recordLanguageServerLog(
                providerID: descriptor.id,
                level: .info,
                message: "Language server activation skipped",
                detail: "Disabled in this workspace"
            )
            return false
        }
        do {
            guard let languageToolingSessions = languageToolingSessionsIfActive else { return false }
            try languageToolingSessions.synchronizeLanguageServer(
                for: document.url,
                text: document.text,
                rootURL: workspaceURL
            )
            languageToolingFeature.markActivationSucceeded(providerID: descriptor.id)
            if let moduleID = services.pluginCatalog.languageSupport(for: document.url)?
                    .declaration.languageServerModuleID {
                // A successful sync is the plugin LSP's latest activity. The
                // idle policy can stop it after the user leaves the document
                // untouched, while subsequent edits refresh this timestamp.
                try? services.moduleRuntime.markIdle(moduleID)
            }
            return languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id)
        } catch {
            languageToolingFeature.markActivationFailed(providerID: descriptor.id, descriptor: descriptor, error: error)
            return false
        }
    }

    func showFindBar() {
        guard activeDocument != nil else { return }
        isFindBarVisible = true
    }

    func hideFindBar() {
        isFindBarVisible = false
        findBarQuery = ""
        findMatchCount = 0
        currentFindMatchIndex = 0
        NotificationCenter.default.post(name: .litheFindDismiss, object: nil)
    }

    func toggleFindBar() {
        if isFindBarVisible {
            hideFindBar()
        } else {
            showFindBar()
        }
    }

    func setFindBarQuery(_ query: String) {
        findBarQuery = query
        NotificationCenter.default.post(
            name: .litheFindQueryChanged,
            object: nil,
            userInfo: [FindNotificationKeys.query: query]
        )
    }

    func navigateFind(offset: Int) {
        NotificationCenter.default.post(
            name: .litheFindNavigate,
            object: nil,
            userInfo: [FindNotificationKeys.direction: offset]
        )
    }

    func updateFindState(currentIndex: Int, count: Int) {
        findMatchCount = count
        currentFindMatchIndex = currentIndex
    }

    func selectChange(_ change: GitChange) {
        activeDocumentID = nil
        Task { [weak self] in
            guard let gitFeature = await self?.activateGitModule() else { return }
            await gitFeature.selectChange(change)
        }
    }

    func reloadSelectedChangeDiff(whitespace: GitDiffWhitespaceMode) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.reloadSelectedChangeDiff(whitespace: whitespace)
    }

    func refreshGit() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.refreshGit()
    }

    func stageSelectedChange() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stageSelectedChange()
    }

    func unstageSelectedChange() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.unstageSelectedChange()
    }

    func stageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stageDiffHunk(hunk, in: change)
    }

    func unstageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.unstageDiffHunk(hunk, in: change)
    }

    func requestDiscardHunk(_ hunk: DiffHunk, in change: GitChange) {
        gitFeatureIfActive?.requestDiscardHunk(hunk, in: change)
    }

    func confirmDiscardHunk() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmDiscardHunk()
    }

    func cancelDiscardHunk() {
        gitFeatureIfActive?.cancelDiscardHunk()
    }

    func requestDiscardSelectedChange() {
        gitFeatureIfActive?.requestDiscardSelectedChange()
    }

    func requestDiscardChange(_ change: GitChange) {
        gitFeatureIfActive?.requestDiscardChange(change)
    }

    func confirmDiscardChange() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmDiscardChange()
    }

    func cancelDiscardChange() {
        gitFeatureIfActive?.cancelDiscardChange()
    }

    func commitStagedChanges() async {
        guard let gitFeature = await activateGitModule() else { return }
        if await gitFeature.commitStagedChanges(message: commitMessage, amend: amendCommit) {
            commitMessage = ""
            amendCommit = false
        }
    }

    func commitAndPushStagedChanges() async {
        guard let gitFeature = await activateGitModule() else { return }
        if await gitFeature.commitAndPushStagedChanges(message: commitMessage, amend: amendCommit) {
            commitMessage = ""
            amendCommit = false
        }
    }

    func generateCommitMessage() async {
        guard !isGeneratingCommitMessage else { return }
        guard let gitFeature = await activateGitModule() else { return }
        let stagedChanges = gitFeature.gitChanges.filter(\.isStaged)
        guard !stagedChanges.isEmpty else {
            showNotification("Stage at least one file first")
            return
        }

        let stagedChangeIDs = Set(stagedChanges.map(\.id))
        isGeneratingCommitMessage = true
        pendingGeneratedCommitMessage = nil
        defer { isGeneratingCommitMessage = false }

        do {
            refreshAIConfigurations()
            guard let input = await gitFeature.stagedCommitMessageInput() else {
                throw CommitMessageGenerationError.emptyDiff
            }
            let value = try await services.moduleRuntime.activateCapability(.aiCommitMessage)
            guard let capability = value as? any AICommitMessageGenerating else {
                throw ModuleRuntimeError.missingCapabilityDependency(
                    module: .aiAssistance,
                    capability: .aiCommitMessage
                )
            }
            defer { try? services.moduleRuntime.markIdle(.aiAssistance) }
            let generated = try await capability.generateCommitMessage(
                input: input,
                settings: settings.commitMessageAI
            )
            let currentStagedChangeIDs = Set(
                gitFeature.gitChanges.filter(\.isStaged).map(\.id)
            )
            guard currentStagedChangeIDs == stagedChangeIDs else {
                showNotification("Staged files changed before generation finished")
                return
            }

            if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitMessage = generated
                showNotification("Commit message generated")
            } else {
                pendingGeneratedCommitMessage = generated
            }
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func applyPendingGeneratedCommitMessage() {
        guard let pendingGeneratedCommitMessage else { return }
        commitMessage = pendingGeneratedCommitMessage
        self.pendingGeneratedCommitMessage = nil
        showNotification("Commit message replaced")
    }

    func discardPendingGeneratedCommitMessage() {
        pendingGeneratedCommitMessage = nil
    }

    func toggleStaging(_ change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.toggleStaging(change)
    }

    func stageAllChanges() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stageAllChanges()
    }

    func toggleGitLog() async {
        isGitLogVisible.toggle()
        if isGitLogVisible {
            isTestsVisible = false
            isTerminalVisible = false
            isReferencesVisible = false
            isProblemsVisible = false
            isMavenVisible = false
            isRunVisible = false
            isDebugVisible = false
        }
        if isGitLogVisible && gitCommits.isEmpty {
            await refreshGitHistory()
        }
    }

    func closeGitLog() {
        isGitLogVisible = false
    }

    func selectGitReference(_ reference: GitReference?) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectGitReference(reference)
    }

    func refreshGitHistory() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.refreshGitHistory()
    }

    func loadMoreGitHistory() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.loadMoreGitHistory()
    }

    func selectGitCommit(_ commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectGitCommit(commit)
    }

    func showGitCommitDiff(for file: GitCommitFile) {
        activeDocumentID = nil
        Task { [weak self] in
            guard let gitFeature = await self?.activateGitModule() else { return }
            await gitFeature.showGitCommitDiff(for: file)
        }
    }

    func closeGitCommitDiff() {
        gitFeatureIfActive?.closeGitCommitDiff()
    }

    func showGitCommit(_ hash: String) async {
        guard let gitFeature = await activateGitModule(),
              gitFeature.gitRepositoryRoot != nil,
              !hash.allSatisfy({ $0 == "0" }) else { return }
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        isTestsVisible = false
        isGitLogVisible = true
        await gitFeature.showGitCommit(hash)
    }

    func showComparisonWithWorkingTree(for reference: GitReference) async {
        activeDocumentID = nil
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.showComparisonWithWorkingTree(for: reference)
    }

    func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectBranchComparisonFile(file)
    }

    func closeBranchComparison() {
        gitFeatureIfActive?.closeBranchComparison()
    }

    func createBranch(
        named rawName: String,
        from reference: GitReference,
        checkout: Bool
    ) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.createBranch(named: rawName, from: reference, checkout: checkout)
    }

    func renameBranch(_ reference: GitReference, to rawName: String) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.renameBranch(reference, to: rawName)
    }

    func deleteBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.deleteBranch(reference)
    }

    func mergeBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.mergeBranch(reference)
    }

    func continueGitOperation() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.continueGitOperation()
    }

    func resolvePullStrategy(_ strategy: GitPullStrategy) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resolvePullStrategy(strategy)
    }

    func cancelPullStrategy() {
        gitFeatureIfActive?.cancelPullStrategy()
    }

    func resolveIntegrationConflict(_ request: GitIntegrationConflictRequest) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resolveIntegrationConflict(request)
    }

    func cancelIntegrationConflict() {
        gitFeatureIfActive?.cancelIntegrationConflict()
    }

    func abortGitOperation() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.abortGitOperation()
    }

    func skipGitOperationStep() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.skipGitOperationStep()
    }

    func rebaseCurrentBranch(onto reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.rebaseCurrentBranch(onto: reference)
    }

    func updateCurrentBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.updateCurrentBranch(reference)
    }

    func fetchGit() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.fetchGit()
    }

    func checkoutReference(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.checkoutReference(reference)
    }

    func resolveCheckoutConflict(
        _ request: GitCheckoutConflictRequest,
        strategy: GitCheckoutConflictStrategy
    ) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resolveCheckoutConflict(request, strategy: strategy)
    }

    func checkoutRevision(_ rawRevision: String) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.checkoutRevision(rawRevision)
    }

    func cherryPick(_ commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.cherryPick(commit)
    }

    func revert(_ commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.revert(commit)
    }

    func resetCurrentBranch(to commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resetCurrentBranch(to: commit)
    }

    func pushBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.pushBranch(reference)
    }

    func loadExternalVersion(of document: EditorDocument) {
        documentFeature.loadExternalVersion(of: document)
    }

    func keepEditorVersion(of document: EditorDocument) {
        documentFeature.keepEditorVersion(of: document)
    }

    func relativePath(for url: URL) -> String {
        guard let workspaceURL else { return url.lastPathComponent }
        return workspaceRelativePath(for: url, root: workspaceURL) ?? url.lastPathComponent
    }

    func showNotification(_ message: String) {
        notificationMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if notificationMessage == message {
                notificationMessage = nil
            }
        }
    }

    func recordSave(_ document: EditorDocument, previousText: String) {
        let snapshot = LocalHistoryDocumentSnapshot(id: document.id, url: document.url, text: document.text)
        withHistoryModule { $0.recordSave(snapshot, previousText: previousText) }
    }

    private func recordDiscardedEditorText(_ document: EditorDocument) {
        let snapshot = LocalHistoryDocumentSnapshot(id: document.id, url: document.url, text: document.text)
        withHistoryModule { $0.recordDiscardedEditorText(snapshot) }
    }
}
