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
import LitheWorkspaceModule
import LitheCoreContracts

@MainActor
final class AppModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var standaloneFileURL: URL?
    @Published var selectedSidebar: SidebarDestination = .project {
        didSet {
            guard oldValue != selectedSidebar else { return }
            sidebarRefreshTask?.cancel()
            sidebarRefreshTask = nil
            // Sidebar changes can happen faster than Git or GitHub can respond.
            // Keep only the refresh associated with the currently visible pane.
            sidebarRefreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                switch self.selectedSidebar {
                case .changes:
                    await self.refreshGit()
                case .pullRequests:
                    guard LitheFeatureAvailability.githubPullRequests else { return }
                    await self.githubFeature.refresh(workspaceURL: self.workspaceURL)
                default:
                    break
                }
            }
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
    let editorChrome = EditorChromeModel()
    let editorDiagnosticsStore = EditorDiagnosticsStore()
    /// 编辑器当前选中的单行文本，供 Find/Replace in Files 预填查询词。
    var editorSelectedText: String {
        get { editorChrome.selectedText }
        set { editorChrome.update(selectedText: newValue) }
    }
    /// 递增令牌：搜索侧栏观察它来把焦点移回输入框。
    @Published var searchSidebarFocusRequest = 0
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
    @Published var activeNotifications: [WorkbenchNotification] = []
    @Published var notifications: [WorkbenchNotification] = []
    var notificationDismissalTasks: [UUID: Task<Void, Never>] = [:]
    var notificationDismissalDeadlines: [UUID: ContinuousClock.Instant] = [:]
    var notificationRemainingDurations: [UUID: Duration] = [:]
    var areNotificationsHovered = false
    @Published var detectedAIConfigurations: [AIConfigurationSnapshot] = []
    @Published var commitMessage = ""
    @Published var amendCommit = false
    @Published private(set) var isGeneratingCommitMessage = false
    @Published private(set) var pendingGeneratedCommitMessage: String?
    @Published var isGitLogVisible = false
    @Published var isTerminalVisible = false
    @Published var pendingTerminalCloseSessionID: UUID?
    var pendingRunAction: PendingRunAction?
    @Published var isReferencesVisible = false
    @Published var isProblemsVisible = false
    @Published var isMavenVisible = false
    @Published var isSpringVisible = false
    @Published var isDebugVisible = false
    @Published var debugBreakpointPresentation = DebugBreakpointPresentationState()
    @Published var isDiscourseCommunityVisible = false
    @Published var isImplementationChooserVisible = false
    var languageProviderCatalog: LanguageProviderCatalog { languageToolingFeature.catalog }
    var languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot { languageToolingFeature.catalogSnapshot }
    @Published var languageNavigationState: LanguageNavigationState = .idle
    var editorCaret: EditorCaret? {
        get { editorChrome.caret }
        set { editorChrome.update(caret: newValue) }
    }
    @Published var editorNavigationTarget: EditorNavigationTarget?
    let navigationHistoryFeature: NavigationHistoryFeatureModel
    var virtualDocumentProviderIDs: [URL: String] = [:]
    var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] {
        javaFeature.javaCodeVisionHints
    }
    @Published var blameVisibleURL: URL?
    @Published var gitLogSearchQuery = ""
    private var shortcutDetector: (any ShortcutDetector)?
    private var sidebarRefreshTask: Task<Void, Never>?
    // Keep the runtime shutdown operation alive and coalesce close paths that
    // can race (for example, project close followed by window teardown).
    private var moduleRuntimeShutdownTask: Task<Void, Never>?
    private var shortcutSettingsObservation: AnyCancellable?
    private var shortcutRecordingObservation: AnyCancellable?
    private var workbenchBackgroundFeatureObservation: AnyCancellable?
    private var isProjectSessionActive = true
    private var fileVisibilityRulesObserverID: UUID?
    private var requestProjectOpen: ((URL) -> Void)?
    private var didCloseProject: (() -> Void)?
    private var securityScopedWorkspaceURL: URL?
    let javaTestWorkflowState = JavaTestWorkflowState()
    let services: AppServices
    let platformUI: any PlatformUI
    let settings: AppSettings
    let keyboardShortcutFeature: KeyboardShortcutFeatureModel
    let workbenchBackgroundFeature: WorkbenchBackgroundFeatureModel
    let runtimeFeature: RuntimeSettingsFeatureModel
    let languageToolingFeature: LanguageToolingFeatureModel
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let debugPortAvailabilityChecker: any DebugPortAvailabilityChecking
    let workspaceFeature: WorkspaceFeatureModel
    let githubFeature: GitHubFeatureModel
    let discourseCommunityFeature: DiscourseCommunityFeatureModel
    let editorTabOrderFeature = EditorTabOrderFeatureModel()
    let mediaFeature = MediaDocumentFeatureModel()
    let terminalPlacementFeature: TerminalPlacementFeatureModel
    var debugTerminalSessionIDs: Set<UUID> = []
    var activeDebugTerminalSessionID: UUID?
    var debugTerminalSessionIDsByDebugSession: [DebugSessionID: Set<UUID>] = [:]
    var activeDebugTerminalSessionIDsByDebugSession: [DebugSessionID: UUID] = [:]
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
    var historyCapability: LitheLocalHistoryModule.HistoryModuleCapability? {
        cachedModuleCapability(.historyWorkspace)
    }
    var gitCapability: LitheGitModule.GitModuleCapability? {
        cachedModuleCapability(.gitWorkspace)
    }
    let documentFeature: DocumentFeatureModel
    let javaFeature: JavaFeatureModel
    let springFeature: SpringFeatureModel
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
            case .pullRequests: moduleID = nil
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
    var rightSidebarContributions: [ModuleContribution] {
        activeModuleContributions.filter { $0.placement == .rightSidebar }
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
        var combined = languageToolingSessionsIfActive?.diagnostics ?? [:]
        for (url, diagnostics) in springFeature.languageDiagnostics {
            combined[url, default: []].append(contentsOf: diagnostics)
        }
        return combined
    }
    var editorDiagnostics: [URL: [EditorDiagnostic]] {
        editorDiagnosticsStore.diagnosticsByURL
    }
    var languageSessionChromeSignature: LanguageSessionChromeSignature?
    private var workspaceFeatureObservation: AnyCancellable?
    private var githubFeatureObservation: AnyCancellable?
    private var runtimeFeatureObservation: AnyCancellable?
    private var editorTabOrderFeatureObservation: AnyCancellable?
    private var terminalPlacementObservation: AnyCancellable?
    private var mediaFeatureObservation: AnyCancellable?, mediaTabCollectionObservation: AnyCancellable?
    private var documentTabCollectionObservation: AnyCancellable?
    private var activeDocumentSelectionObservation: AnyCancellable?
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

    private var documentFeatureObservation: AnyCancellable?
    private var javaFeatureObservation: AnyCancellable?
    private var springFeatureObservation: AnyCancellable?
    private var navigationHistoryFeatureObservation: AnyCancellable?
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
        keyboardShortcutFeature = KeyboardShortcutFeatureModel(settings: settings)
        workbenchBackgroundFeature = WorkbenchBackgroundFeatureModel(settings: settings, platform: services.workbenchBackgroundPlatform)
        discourseCommunityFeature = DiscourseCommunityFeatureModel(service: services.discourseCommunityService)
        terminalPlacementFeature = TerminalPlacementFeatureModel()
        workspaceFeature = WorkspaceFeatureModel(
            operations: services.workspaceOperations,
            fileOperations: services.fileOperations,
            gitWatchContextProvider: services.gitWatchContextProvider,
            directoryWatcherFactory: services.directoryWatcherFactory,
            workspaceSessionStore: services.workspaceSessionStore
        )
        githubFeature = GitHubFeatureModel(service: services.githubService)
        Task { @MainActor [workspaceFeature, moduleRuntime = services.moduleRuntime] in
            guard let capability = try? await moduleRuntime.activateCapability(.workspaceFoundation),
                  let capability = capability as? LitheWorkspaceModule.WorkspaceFoundationCapability else { return }
            capability.attach(workspaceProjection: workspaceFeature)
        }
        runtimeFeature = RuntimeSettingsFeatureModel(service: services.projectRuntimeService)
        languageToolingFeature = LanguageToolingFeatureModel(
            catalogSource: services.languageProviderCatalogSource,
            catalogSnapshot: services.languageProviderCatalogSnapshot,
            sessionsProvider: { nil }
        )
        debugLaunchConfigurationResolver = services.debugLaunchConfigurationResolver
        debugPortAvailabilityChecker = services.debugPortAvailabilityChecker
        documentFeature = DocumentFeatureModel(
            operations: services.workspaceOperations,
            documentLifecycleDecider: services.documentLifecycleDecider,
            fileOperations: services.fileOperations,
            fileStorage: services.fileStorage,
            binaryFileViewerRegistry: services.binaryFileViewerRegistry
        )
        navigationHistoryFeature = NavigationHistoryFeatureModel()
        javaFeature = JavaFeatureModel(operations: services.javaMavenOperations)
        springFeature = SpringFeatureModel(operations: services.javaMavenOperations)
        recentProjects = services.recentProjectsStore.load()
        languageToolingFeature.configureSessions { [weak self] in
            self?.languageToolingSessionsIfActive
        }
        workbenchBackgroundFeatureObservation = workbenchBackgroundFeature.objectWillChange.sink { [weak self] _ in self?.scheduleObjectWillChangeRelay() }
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
        githubFeatureObservation = githubFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        runtimeFeatureObservation = runtimeFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        navigationHistoryFeatureObservation = navigationHistoryFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        editorTabOrderFeatureObservation = editorTabOrderFeature.objectWillChange
            .sink { [weak self] _ in self?.scheduleObjectWillChangeRelay() }
        terminalPlacementObservation = terminalPlacementFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        activeDocumentSelectionObservation = documentFeature.$activeDocumentID
            .dropFirst()
            .sink { [weak self] documentID in
                guard documentID != nil else { return }
                self?.terminalPlacementFeature.activateDocument()
            }
        if LitheFeatureAvailability.githubPullRequests {
            Task { [weak self] in
                guard let self else { return }
                await self.githubFeature.restore(workspaceURL: self.workspaceURL)
            }
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
                let restoredSidebar = SidebarDestination(rawValue: session.selectedSidebar) ?? .project
                self.selectedSidebar = restoredSidebar.isAvailable ? restoredSidebar : .project
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
            notifyWorkspaceFileChanges: { [weak self] changes in
                self?.handleJavaWorkspaceFileChanges(changes)
            },
            reloadProjectServices: { [weak self] in
                guard let self, let workspaceURL = self.workspaceURL else { return }
                await self.loadProjectServicesForAppliedSnapshot(at: workspaceURL)
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
                guard let self else { return }
                // The snapshot callback owns the transition from a provisional
                // inventory to a ready run project and resumes any deferred action.
                await self.loadProjectServices(
                    at: snapshot.root.url,
                    files: snapshot.files,
                    snapshotID: snapshot.id,
                    resumesDeferredRunAction: true
                )
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
                guard let self, self.workspaceURL != nil else { return }
                self.workspaceFeature.scheduleWorkspaceSessionPersistence()
            },
            onProjectCloseReady: { [weak self] in
                guard let self else { return }
                if self.workspaceURL != nil {
                    self.performCloseProject()
                } else if self.standaloneFileURL != nil {
                    self.performCloseStandaloneFile()
                }
            }
        )
        documentFeatureObservation = documentFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        documentTabCollectionObservation = documentFeature.$openDocuments
            .map { $0.map(\.id) }.removeDuplicates()
            .sink { [weak self] ids in self?.editorTabOrderFeature.reconcileDocuments(orderedIDs: ids) }
        mediaFeatureObservation = mediaFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        mediaTabCollectionObservation = mediaFeature.$openMediaDocuments
            .map { $0.map(\.id) }.removeDuplicates()
            .sink { [weak self] ids in self?.editorTabOrderFeature.reconcileMedia(orderedIDs: ids) }
        javaFeature.configure(
            documentProvider: { [weak self] in self?.activeDocument },
            loadBlame: { [weak self] fileURL in
                guard let self else { return [] }
                guard let feature = await self.activateGitModule() else { return [] }
                return await feature.loadBlame(for: fileURL)
            }
        )
        javaFeatureObservation = javaFeature.objectWillChange.sink { [weak self] _ in
            self?.scheduleObjectWillChangeRelay()
        }
        springFeatureObservation = springFeature.objectWillChange.sink { [weak self] _ in
            self?.refreshEditorDiagnosticsStore()
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
        shortcutDetector = services.shortcutDetectorFactory.make { [weak self] commandID in
            self?.performShortcutCommand(id: commandID)
        }
        refreshShortcutDetector()
        shortcutSettingsObservation = settings.$keyboardShortcutOverrides
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshShortcutDetector()
                    self?.scheduleObjectWillChangeRelay()
                }
            }
        shortcutRecordingObservation = keyboardShortcutFeature.$recordingCommandID
            .sink { [weak self] commandID in
                self?.shortcutDetector?.setSuspended(commandID != nil)
            }
        configureMediaViewerRegistry()
        shortcutDetector?.start()
    }

    private func refreshShortcutDetector() {
        shortcutDetector?.update(registrations: keyboardShortcutFeature.registrations)
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
        shortcutDetector?.stop()
        sidebarRefreshTask?.cancel()
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
            shortcutDetector?.start()
        } else {
            shortcutDetector?.stop()
            isSearchEverywhereVisible = false
        }
    }

    func shutdownProjectSession() async {
        shortcutDetector?.stop()
        cancelJavaTestWorkflows()
        languageToolingSessionsIfActive?.stopAll()
        languageTestServiceIfActive?.stop()
        stopTerminalSessions()
        stopAccessingWorkspace()
        if let fileVisibilityRulesObserverID {
            settings.removeFileVisibilityRulesObserver(fileVisibilityRulesObserverID)
            self.fileVisibilityRulesObserverID = nil
        }
        await shutdownModuleRuntime()
    }

    /// Records this session's module-graph teardown before it can yield, so an
    /// on-demand activation that follows a project switch can join the same
    /// operation instead of racing a capability release.
    private func beginModuleRuntimeShutdown() {
        guard moduleRuntimeShutdownTask == nil else { return }
        let moduleRuntime = services.moduleRuntime
        moduleRuntimeShutdownTask = Task { @MainActor [weak self] in
            await moduleRuntime.shutdownAll()
            guard let self else { return }
            self.moduleRuntimeShutdownTask = nil
            self.clearModuleBindings(for: .database)
        }
    }

    /// Shuts down this session's module graph once, even when multiple
    /// lifecycle paths request cleanup at the same time.
    private func shutdownModuleRuntime() async {
        beginModuleRuntimeShutdown()
        await moduleRuntimeShutdownTask?.value
    }

    /// Lets an on-demand activation resume after a session teardown finishes.
    ///
    /// A shutdown that starts while this wait is suspended is joined as well, so
    /// activation never returns a capability the runtime is about to release.
    func awaitModuleRuntimeShutdown() async {
        while let shutdownTask = moduleRuntimeShutdownTask {
            await shutdownTask.value
        }
    }

    private func reloadJavaRuntimeServices() {
        cancelJavaTestWorkflows()
        genericDebugFeatureIfActive?.stop()
        mavenFeatureIfActive?.stop()
        languageToolingSessionsIfActive?.stopLanguageServer(providerID: "java")
        javaFeature.stop()
        springFeature.reset()
        if let workspaceURL {
            if let document = activeDocument,
               document.url.pathExtension.lowercased() == "java" {
                activateLanguageServerIfAvailable(for: document)
            }
            Task { [weak self] in
                guard let self else { return }
                await self.loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
        }
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
        cancelJavaLanguageServerPreparation()
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

    func javaStructure(source: String, declarationSources: [String] = []) async -> JavaStructureResult? {
        await javaFeature.structure(source: source, declarationSources: declarationSources)
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
        beginModuleRuntimeShutdown()
        if let previousWorkspaceURL = workspaceURL {
            workspaceFeature.persistWorkspaceSession(for: previousWorkspaceURL)
        }
        // A workspace root is a hard language-server ownership boundary. Stop
        // every provider session before replacing the catalog or clearing the
        // document projection so no old-root documents, diagnostics, or
        // responses can survive into the next workspace.
        cancelJavaWorkspaceWorkflows()
        languageToolingSessionsIfActive?.stopAll()
        reloadLanguageProviderCatalog(for: normalizedURL)
        stopTerminalSessions()
        languageTestServiceIfActive?.reset()
        languageToolingFeature.resetWorkspaceState()
        runtimeFeature.openProject(at: normalizedURL)
        mavenFeatureIfActive?.reset()
        runFeatureIfActive?.reset()
        pendingRunAction = nil
        scheduleObjectWillChangeRelay()
        genericDebugFeatureIfActive?.reset()
        debugBreakpointPresentation.reset()
        clearLanguageNavigationProjection()
        javaFeature.stop()
        springFeature.reset()
        workspaceFeature.reset()
        searchFeatureIfActive?.reset()
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isSpringVisible = false
        isRunVisible = false
        isTestsVisible = false
        isDebugVisible = false
        editorChrome.reset()
        editorDiagnosticsStore.reset()
        editorNavigationTarget = nil
        navigationHistoryFeature.reset()
        virtualDocumentProviderIDs.removeAll()
        blameVisibleURL = nil
        gitFeatureIfActive?.reset()
        documentFeature.reset()
        mediaFeature.reset()
        gitLogSearchQuery = ""
        projectHistoryFeatureIfActive?.reset()
        workspaceURL = normalizedURL
        standaloneFileURL = nil
        let visibilityRules = settings.fileVisibilityRules
        workspaceFeature.beginWorkspace(at: normalizedURL, visibilityRules: visibilityRules)
        selectedSidebar = .project
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        recentProjects = recentProjectsStore.record(normalizedURL, in: recentProjects)

        // The rebuild belongs to this opening. Reopening the same path advances
        // the generation, so a rebuild left over from the previous opening
        // cannot publish its snapshot into this one.
        let generation = workspaceFeature.workspaceGeneration
        Task {
            await restoreDebugBreakpoints(for: normalizedURL)
            guard workspaceURL == normalizedURL,
                  workspaceFeature.workspaceGeneration == generation else { return }
            _ = await workspaceFeature.rebuild(
                at: normalizedURL,
                rules: visibilityRules,
                isCurrent: { [weak self] in
                    self?.workspaceURL == normalizedURL
                        && self?.workspaceFeature.workspaceGeneration == generation
                }
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

    func closeStandaloneFile() {
        guard standaloneFileURL != nil else { return }
        guard documentFeature.beginProjectClose() else {
            performCloseStandaloneFile()
            return
        }
    }

    private func performCloseProject() {
        cancelJavaLanguageServerPreparation()
        beginModuleRuntimeShutdown()
        if let workspaceURL {
            workspaceFeature.persistWorkspaceSession(for: workspaceURL)
        }
        stopAccessingWorkspace()
        workspaceURL = nil
        standaloneFileURL = nil
        reloadLanguageProviderCatalog(for: nil)
        selectedSidebar = .project
        workspaceFeature.reset()
        documentFeature.reset()
        mediaFeature.reset()
        searchFeatureIfActive?.reset()
        searchQuery = ""
        isSearchEverywhereVisible = false
        searchEverywhereQuery = ""
        isProjectReplaceVisible = false
        projectReplaceQuery = ""
        projectReplaceText = ""
        selectedProjectReplacementPaths = []
        editorChrome.resetFindBar()
        editorDiagnosticsStore.reset()
        projectHistoryFeatureIfActive?.reset()
        workspaceFeature.reset()
        gitFeatureIfActive?.reset()
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isSpringVisible = false
        isRunVisible = false
        isTestsVisible = false
        isDebugVisible = false
        stopTerminalSessions()
        cancelJavaWorkspaceWorkflows()
        languageToolingSessionsIfActive?.stopAll()
        languageTestServiceIfActive?.reset()
        runtimeFeature.closeProject()
        mavenFeatureIfActive?.reset()
        runFeatureIfActive?.reset()
        pendingRunAction = nil
        scheduleObjectWillChangeRelay()
        genericDebugFeatureIfActive?.reset()
        debugBreakpointPresentation.reset()
        javaFeature.stop()
        springFeature.reset()
        editorChrome.reset()
        editorNavigationTarget = nil
        navigationHistoryFeature.reset()
        virtualDocumentProviderIDs.removeAll()
        blameVisibleURL = nil
        gitLogSearchQuery = ""
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        refreshRecentProjects()
        didCloseProject?()
    }

    private func performCloseStandaloneFile() {
        standaloneFileURL = nil
        documentFeature.reset()
        mediaFeature.reset()
        editorChrome.resetFindBar()
        editorChrome.setGoToLineVisible(false)
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
        editorNavigationTarget = nil
        documentFeature.openFile(url, isReadOnly: isReadOnly, displayPath: displayPath)
    }

    func openStandaloneFile(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        workspaceURL = nil
        standaloneFileURL = normalizedURL
        documentFeature.reset()
        mediaFeature.reset()
        isFindBarVisible = false
        findBarQuery = ""
        if let mediaKind = MediaDocumentKind.from(url: normalizedURL) {
            openMediaFile(normalizedURL, kind: mediaKind)
        } else {
            documentFeature.openStandaloneFile(normalizedURL)
        }
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

    func confirmProjectItemDeletion(_ request: ProjectItemDeletionRequest) async {
        await workspaceFeature.confirmProjectItemDeletion(request)
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
        if let workspaceURL {
            springFeature.scheduleReload(
                changedDocument: document,
                workspaceURL: workspaceURL,
                files: projectFiles,
                openDocuments: openDocuments
            )
        }
        Task { @MainActor [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, let document else { return }
            guard self.javaFeature.handles(fileURL: document.url) else { return }
            await self.refreshCodeVision(for: document.url)
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
    func activateLanguageServerIfAvailable(for document: EditorDocument) -> Bool {
        guard let workspaceURL,
              let descriptor = languageProviderCatalog.provider(for: document.url) else { return false }
        if descriptor.id == "java" {
            switch prepareJavaLanguageServerRuntimeIfNeeded(for: document) {
            case .ready: break
            case .preparing: return false
            }
        }
        if let ownership = services.pluginCatalog.languageSupport(for: document.url),
           let moduleID = ownership.declaration.languageServerModuleID {
            let support = ownership.declaration
            // Static plugin metadata may exist before a native plugin is loaded.
            // Only a registered and enabled module may enter LSP activation.
            guard let snapshot = try? services.moduleRuntime.snapshot(for: moduleID),
                  snapshot.state != .disabled else {
                return false
            }
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
                    self.bindLanguageIntelligenceCapability(capability)
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

    func generatePullRequestDescription(
        base: String,
        head: String
    ) async throws -> PullRequestDescriptionOutput {
        guard LitheFeatureAvailability.githubPullRequests else {
            throw GitHubService.ServiceError.oauthClientNotConfigured
        }
        refreshAIConfigurations()
        let input = try await githubFeature.pullRequestDescriptionInput(base: base, head: head)
        let value = try await services.moduleRuntime.activateCapability(.aiPullRequestDescription)
        guard let capability = value as? any AIPullRequestDescriptionGenerating else {
            throw ModuleRuntimeError.missingCapabilityDependency(
                module: .aiAssistance,
                capability: .aiPullRequestDescription
            )
        }
        defer { try? services.moduleRuntime.markIdle(.aiAssistance) }
        return try await capability.generatePullRequestDescription(
            input: input,
            settings: settings.commitMessageAI
        )
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

    func toggleStaging(_ change: GitChange) {
        guard let gitFeature = gitFeatureIfActive else { return }
        guard let staged = gitFeature.beginToggleStaging(change) else { return }
        Task { await gitFeature.finishToggleStaging(change, staged: staged) }
    }

    func setStaging(_ changes: [GitChange], staged: Bool) {
        guard let gitFeature = gitFeatureIfActive else { return }
        let pendingChanges = gitFeature.beginSetStaging(changes, staged: staged)
        Task { await gitFeature.finishSetStaging(pendingChanges, staged: staged) }
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
        } else if !isGitLogVisible {
            gitFeatureIfActive?.cancelGitHistoryLoading()
        }
    }

    func closeGitLog() {
        isGitLogVisible = false
        gitFeatureIfActive?.cancelGitHistoryLoading()
    }

    func selectGitReference(_ reference: GitReference?) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectGitReference(reference)
    }

    func showAllGitReferences() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.showAllGitReferences()
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

    func applyGitLogFilter(_ query: String) async {
        await applyGitLogFilter(GitLogQuery.parse(query))
    }

    func applyGitLogFilter(_ query: GitLogQuery) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.applyGitLogFilter(query)
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

    func showComparison(from reference: GitReference, to target: GitReference) async {
        activeDocumentID = nil
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.showComparison(from: reference, to: target)
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

    func restoreRecentlyDeletedBranch() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.restoreRecentlyDeletedBranch()
    }

    func dismissDeletedBranchBanner() {
        gitFeatureIfActive?.dismissDeletedBranchBanner()
    }

    /// Returns nil on success, otherwise the error message a tag dialog
    /// should show where the user typed.
    @discardableResult
    func createTag(at commit: GitCommit, name: String, message: String) async -> String? {
        guard let gitFeature = await activateGitModule() else { return "No Git repository is open" }
        return await gitFeature.createTag(at: commit, name: name, message: message)
    }

    func deleteTag(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.deleteTag(reference)
    }

    func restoreRecentlyDeletedTag() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.restoreRecentlyDeletedTag()
    }

    func dismissDeletedTagBanner() {
        gitFeatureIfActive?.dismissDeletedTagBanner()
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

    func checkoutAndRebase(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.checkoutAndRebase(reference)
    }

    func pullRemoteReference(_ reference: GitReference, strategy: GitPullStrategy) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.pullRemoteReference(reference, strategy: strategy)
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

}
