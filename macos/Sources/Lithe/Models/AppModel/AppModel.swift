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
    var workspaceURL: URL? { workspaceSessionCoordinator.workspaceURL }
    var standaloneFileURL: URL? { workspaceSessionCoordinator.standaloneFileURL }
    var searchSessionFeature: SearchSessionFeatureModel { featureGraph.searchSession }
    lazy var searchWorkflow = SearchWorkflowComposition.make(model: self)
    lazy var projectReplacement = ProjectReplacementComposition.make(model: self)
    var searchQuery: String {
        get { searchSessionFeature.query }
        set { searchSessionFeature.query = newValue }
    }
    var isSearchEverywhereVisible: Bool {
        get { searchSessionFeature.isSearchEverywhereVisible }
        set { searchSessionFeature.isSearchEverywhereVisible = newValue }
    }
    // Search Everywhere owns its transient query so typing does not publish a
    // change through the whole workbench.
    var searchEverywhereQuery: String {
        get { searchSessionFeature.everywhereQuery }
        set { searchSessionFeature.everywhereQuery = newValue }
    }
    var isProjectReplaceVisible: Bool {
        get { searchSessionFeature.isProjectReplaceVisible }
        set { searchSessionFeature.isProjectReplaceVisible = newValue }
    }
    var projectReplaceQuery: String {
        get { searchSessionFeature.replacementQuery }
        set { searchSessionFeature.replacementQuery = newValue }
    }
    var projectReplaceText: String {
        get { searchSessionFeature.replacementText }
        set { searchSessionFeature.replacementText = newValue }
    }
    /// Replace in Project 面板的搜索选项（Preserve Case、文件掩码等）。
    var projectReplaceOptions: ProjectSearchOptions {
        get { searchSessionFeature.replacementOptions }
        set { searchSessionFeature.replacementOptions = newValue }
    }
    var selectedProjectReplacementPaths: Set<String> {
        get { searchSessionFeature.selectedReplacementPaths }
        set { searchSessionFeature.selectedReplacementPaths = newValue }
    }
    let editorChrome = EditorChromeModel()
    let editorDiagnosticsStore = EditorDiagnosticsStore()
    /// 编辑器当前选中的单行文本，供 Find/Replace in Files 预填查询词。
    var editorSelectedText: String {
        get { editorChrome.selectedText }
        set { editorChrome.update(selectedText: newValue) }
    }
    /// 递增令牌：搜索侧栏观察它来把焦点移回输入框。
    var searchSidebarFocusRequest: Int {
        get { searchSessionFeature.sidebarFocusRequest }
        set { searchSessionFeature.sidebarFocusRequest = newValue }
    }
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
    @Published var detectedAIConfigurations: [AIConfigurationSnapshot] = []
    var commitDraftFeature: CommitDraftFeatureModel { featureGraph.commitDraft }
    lazy var commitWorkflow = CommitWorkflowComposition.make(model: self)
    var commitMessage: String {
        get { commitDraftFeature.message }
        set { commitDraftFeature.message = newValue }
    }
    var amendCommit: Bool {
        get { commitDraftFeature.amend }
        set { commitDraftFeature.amend = newValue }
    }
    var isGeneratingCommitMessage: Bool { commitDraftFeature.isGenerating }
    var pendingGeneratedCommitMessage: String? { commitDraftFeature.pendingGeneratedMessage }
    @Published var pendingTerminalCloseSessionID: UUID?
    var pendingRunAction: PendingRunAction? { runWorkflowCoordinator.pendingAction }
    @Published var debugBreakpointPresentation = DebugBreakpointPresentationState()
    @Published var isDiscourseCommunityVisible = false
    @Published var isImplementationChooserVisible = false
    var languageProviderCatalog: LanguageProviderCatalog { languageToolingFeature.catalog }
    var languageProviderCatalogSnapshot: LanguageProviderCatalogSnapshot { languageToolingFeature.catalogSnapshot }
    var languageNavigationState: LanguageNavigationState {
        languageNavigationCoordinator.state
    }
    var editorCaret: EditorCaret? {
        get { editorChrome.caret }
        set { editorChrome.update(caret: newValue) }
    }
    @Published var editorNavigationTarget: EditorNavigationTarget?
    var navigationHistoryFeature: NavigationHistoryFeatureModel {
        featureGraph.navigationHistory
    }
    var virtualDocumentProviderIDs: [URL: String] = [:]
    var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] {
        javaFeature.javaCodeVisionHints
    }
    @Published var blameVisibleURL: URL?
    private var shortcutSessionCoordinator: ShortcutSessionCoordinator?
    private var documentLanguageCoordinator: DocumentLanguageCoordinator?
    private var sidebarRefreshTask: Task<Void, Never>?
    private var moduleSessionCoordinator: ModuleSessionCoordinator?
    private var featureObservationBinder: AppModelObservationBinder?
    private var fileVisibilityRulesObserverID: UUID?
    private var requestProjectOpen: ((URL) -> Void)?
    private var didCloseProject: (() -> Void)?
    var javaTestWorkflowState: JavaTestWorkflowState {
        featureGraph.javaTestWorkflow
    }
    var languageNavigationCoordinator: LanguageNavigationCoordinator {
        featureGraph.languageNavigation
    }
    let services: AppServices
    let platformUI: any PlatformUI
    let settings: AppSettings
    let featureGraph: AppModelFeatureGraph
    var workbenchFeature: WorkbenchFeatureModel { featureGraph.workbench }
    var workspaceSessionCoordinator: WorkspaceSessionCoordinator {
        featureGraph.workspaceSession
    }
    var recentProjects: [RecentProject] {
        workspaceSessionCoordinator.recentProjects
    }
    var isSettingsPresented: Bool {
        get { workbenchFeature.isSettingsPresented }
        set { workbenchFeature.isSettingsPresented = newValue }
    }
    var requestedSettingsCategory: SettingsCategory {
        workbenchFeature.requestedSettingsCategory
    }
    var isCloneRepositoryPresented: Bool {
        get { workbenchFeature.isCloneRepositoryPresented }
        set { workbenchFeature.isCloneRepositoryPresented = newValue }
    }
    var keyboardShortcutFeature: KeyboardShortcutFeatureModel { featureGraph.keyboardShortcut }
    var notificationFeature: WorkbenchNotificationFeatureModel { featureGraph.notification }
    var workbenchBackgroundFeature: WorkbenchBackgroundFeatureModel { featureGraph.workbenchBackground }
    var runtimeFeature: RuntimeSettingsFeatureModel { featureGraph.runtime }
    var languageToolingFeature: LanguageToolingFeatureModel { featureGraph.languageTooling }
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let debugPortAvailabilityChecker: any DebugPortAvailabilityChecking
    var workspaceFeature: WorkspaceFeatureModel { featureGraph.workspace }
    var githubFeature: GitHubFeatureModel { featureGraph.github }
    var discourseCommunityFeature: DiscourseCommunityFeatureModel {
        featureGraph.discourseCommunity
    }
    var editorTabOrderFeature: EditorTabOrderFeatureModel { featureGraph.editorTabOrder }
    var mediaFeature: MediaDocumentFeatureModel { featureGraph.media }
    var terminalPlacementFeature: TerminalPlacementFeatureModel {
        featureGraph.terminalPlacement
    }
    var debugTerminalSessionIDs: Set<UUID> = []
    var activeDebugTerminalSessionID: UUID?
    var debugTerminalSessionIDsByDebugSession: [DebugSessionID: Set<UUID>] = [:]
    var activeDebugTerminalSessionIDsByDebugSession: [DebugSessionID: UUID] = [:]
    let moduleCapabilityStore: ModuleCapabilityStore
    lazy var executionModuleCoordinator = ExecutionModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        awaitShutdown: { [weak self] in await self?.awaitModuleRuntimeShutdown() },
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() },
        onError: { [weak self] in self?.showNotification($0) }
    )
    lazy var debugModuleCoordinator = DebugModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        awaitShutdown: { [weak self] in await self?.awaitModuleRuntimeShutdown() },
        configure: { [weak self] in self?.configureDebugHostHandlers($0) },
        openWorkspace: { feature, url in feature.openWorkspace(at: url) },
        onStateChange: { [weak self] in self?.handleDebugSessionStateChange($0) },
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() },
        onError: { [weak self] in self?.showNotification($0) }
    )
    lazy var languageIntelligenceModuleCoordinator = LanguageIntelligenceModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        bind: { [weak self] in self?.bindLanguageIntelligenceCapability($0) },
        notify: { [weak self] in self?.showNotification($0) }
    )
    lazy var terminalModuleCoordinator = TerminalModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() }
    )
    lazy var gitModuleCoordinator = GitModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() },
        onError: { [weak self] in self?.showNotification($0) }
    )
    let javaLanguageServerPreparationCoordinator = JavaLanguageServerPreparationCoordinator()
    lazy var historyModuleCoordinator = HistoryModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        workspace: { [weak self] in self?.workspaceURL },
        settings: { [weak self] in
            self?.settings.fileVisibilityRules.localHistoryRules
                ?? LocalHistoryVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        },
        files: { [weak self] in self?.projectFiles ?? [] },
        documents: { [weak self] in
            self?.openDocuments.map {
                LocalHistoryDocumentSnapshot(id: $0.id, url: $0.url, text: $0.text)
            } ?? []
        },
        notify: { [weak self] in self?.showNotification($0) },
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() }
    )
    lazy var databaseModuleCoordinator = DatabaseModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() },
        onError: { [weak self] in self?.showNotification($0) }
    )
    lazy var searchModuleCoordinator = SearchModuleCoordinator(
        runtime: services.moduleRuntime,
        store: moduleCapabilityStore,
        workspace: { [weak self] in self?.workspaceURL },
        visibilityRules: { [weak self] in self?.settings.fileVisibilityRules ?? .default },
        onChange: { [weak self] in self?.scheduleObjectWillChangeRelay() },
        onError: { [weak self] in self?.showNotification($0) }
    )
    lazy var runWorkflowCoordinator = RunWorkflowCoordinator(
        pluginCatalog: services.pluginCatalog,
        moduleRuntime: services.moduleRuntime,
        notify: { [weak self] in self?.showNotification($0) },
        onPendingActionChange: { [weak self] in self?.scheduleObjectWillChangeRelay() }
    )
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
    var documentFeature: DocumentFeatureModel { featureGraph.document }
    var javaFeature: JavaFeatureModel { featureGraph.java }
    var springFeature: SpringFeatureModel { featureGraph.spring }
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

    var detectedCodexConfiguration: CodexConfigurationSnapshot? {
        detectedAIConfigurations.first { $0.source == .codex }
    }

    var detectedClaudeConfiguration: AIConfigurationSnapshot? {
        detectedAIConfigurations.first { $0.source == .claude }
    }

    func showSettings(category: SettingsCategory = .general) {
        workbenchFeature.presentSettings(category: category)
    }

    private var springFeatureObservation: AnyCancellable?
    private var isObjectWillChangeRelayScheduled = false
    private var languageToolingObservation: AnyCancellable?

    func cachedModuleCapability<Capability: AnyObject>(
        _ id: ModuleCapabilityID,
        as type: Capability.Type = Capability.self
    ) -> Capability? {
        moduleCapabilityStore.capability(id, as: type)
    }

    func activateModuleCapability<Capability: AnyObject>(
        _ id: ModuleCapabilityID,
        as type: Capability.Type = Capability.self,
        moduleID: ModuleID
    ) async throws -> Capability {
        try await moduleCapabilityStore.activate(
            id,
            as: type,
            moduleID: moduleID,
            using: services.moduleRuntime.activateCapability
        )
    }

    func cacheModuleCapability(
        _ capability: AnyObject,
        id: ModuleCapabilityID,
        moduleID: ModuleID
    ) {
        moduleCapabilityStore.cache(capability, id: id, moduleID: moduleID)
    }

    func clearModuleBindings(for moduleID: ModuleID) {
        moduleSessionCoordinator?.clearBindings(for: moduleID)
    }

    private func unregisterModuleLanguageExtensions(for moduleID: ModuleID) {
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
        moduleCapabilityStore.observe(moduleID, observation: observation)
    }

    func scheduleObjectWillChangeRelay() {
        guard !isObjectWillChangeRelayScheduled else { return }
        isObjectWillChangeRelayScheduled = true
        let signpost = LitheSignpost.begin("appmodel.relay")
        Task { @MainActor [weak self] in
            defer { LitheSignpost.end("appmodel.relay", signpost) }
            guard let self else { return }
            self.isObjectWillChangeRelayScheduled = false
            self.objectWillChange.send()
        }
    }

    init(
        settings: AppSettings,
        services: AppServices,
        featureGraph: AppModelFeatureGraph
    ) {
        self.settings = settings
        self.services = services
        platformUI = services.platformUI
        self.featureGraph = featureGraph
        moduleCapabilityStore = ModuleCapabilityStore()
        Task { @MainActor [workspaceFeature = featureGraph.workspace, moduleRuntime = services.moduleRuntime] in
            guard let capability = try? await moduleRuntime.activateCapability(.workspaceFoundation),
                  let capability = capability as? LitheWorkspaceModule.WorkspaceFoundationCapability else { return }
            capability.attach(workspaceProjection: workspaceFeature)
        }
        debugLaunchConfigurationResolver = services.debugLaunchConfigurationResolver
        debugPortAvailabilityChecker = services.debugPortAvailabilityChecker
        workbenchFeature.configure { [weak self] destination in
            self?.handleSidebarSelectionChanged(destination)
        }
        workspaceSessionCoordinator.configureLifecycle(
            with: WorkspaceSessionCoordinator.LifecycleHandlers(
                prepareForWorkspaceOpen: { [weak self] url in
                    self?.prepareForWorkspaceOpen(at: url)
                },
                prepareForWorkspaceClose: { [weak self] url in
                    self?.finishWorkspaceClose(for: url)
                },
                prepareForStandaloneOpen: { [weak self] url in
                    self?.prepareForStandaloneOpen(at: url)
                },
                finishStandaloneClose: { [weak self] in
                    self?.finishStandaloneClose()
                },
                beginDocumentClose: { [weak self] in
                    self?.documentFeature.beginProjectClose() ?? false
                },
                restoreDebugBreakpoints: { [weak self] url in
                    await self?.restoreDebugBreakpoints(for: url)
                },
                visibilityRules: { [weak self] in
                    self?.settings.fileVisibilityRules ?? .default
                }
            )
        )
        languageToolingFeature.configureSessions { [weak self] in
            self?.languageToolingSessionsIfActive
        }
        featureObservationBinder = AppModelObservationBinder(graph: featureGraph) { [weak self] in
            self?.scheduleObjectWillChangeRelay()
        }
        runWorkflowCoordinator.connect(actions: self)
        featureGraph.debugLaunchPreparation.connect(actions: self)
        featureGraph.javaTestDebugWorkflow.connect(actions: self)
        featureGraph.debugSessionCleanup.connect(actions: self)
        moduleSessionCoordinator = ModuleSessionCoordinator(
            runtime: services.moduleRuntime,
            capabilities: moduleCapabilityStore,
            workbench: workbenchFeature,
            onModuleReleased: { [weak self] moduleID in
                self?.unregisterModuleLanguageExtensions(for: moduleID)
            },
            onChange: { [weak self] in
                self?.scheduleObjectWillChangeRelay()
            }
        )
        if LitheFeatureAvailability.githubPullRequests {
            Task { [weak self] in
                guard let self else { return }
                await self.githubFeature.restore(workspaceURL: self.workspaceURL)
            }
        }
        WorkspaceProjectionComposition.configure(model: self)
        documentLanguageCoordinator = DocumentFeatureComposition.configure(model: self)
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
        shortcutSessionCoordinator = ShortcutSessionCoordinator(
            settings: settings,
            feature: keyboardShortcutFeature,
            factory: services.shortcutDetectorFactory,
            onRegistrationsChanged: { [weak self] in
                self?.scheduleObjectWillChangeRelay()
            },
            onCommand: { [weak self] commandID in
                self?.performShortcutCommand(id: commandID)
            }
        )
        configureMediaViewerRegistry()
        shortcutSessionCoordinator?.setActive(true)
    }

    convenience init(settings: AppSettings, services: AppServices) {
        self.init(
            settings: settings,
            services: services,
            featureGraph: AppModelFeatureGraph(settings: settings, services: services)
        )
    }

    private func handleSidebarSelectionChanged(_ destination: SidebarDestination) {
        sidebarRefreshTask?.cancel()
        sidebarRefreshTask = nil
        // Sidebar changes can happen faster than Git or GitHub can respond.
        // Keep only the refresh associated with the currently visible pane.
        sidebarRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            switch destination {
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

    func activateDatabaseModule() async {
        guard await databaseModuleCoordinator.activate() != nil else { return }
        selectedSidebar = .database
    }

    func sleepDatabaseModule() async {
        await databaseModuleCoordinator.sleep()
        if selectedSidebar == .database { selectedSidebar = .project }
    }

    deinit {
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
        guard workspaceSessionCoordinator.setActive(isActive) else { return }
        shortcutSessionCoordinator?.setActive(isActive)
        if !isActive {
            searchSessionFeature.isSearchEverywhereVisible = false
            cancelJavaLanguageServerPreparation()
        }
    }

    func shutdownProjectSession() async {
        shortcutSessionCoordinator?.shutdown()
        documentLanguageCoordinator?.stop()
        cancelJavaTestWorkflows()
        languageToolingSessionsIfActive?.stopAll()
        executionModuleCoordinator.stopTests(languageTestServiceIfActive)
        stopTerminalSessions()
        workspaceSessionCoordinator.stopSessionResources()
        if let fileVisibilityRulesObserverID {
            settings.removeFileVisibilityRulesObserver(fileVisibilityRulesObserverID)
            self.fileVisibilityRulesObserverID = nil
        }
        await shutdownModuleRuntime()
        moduleSessionCoordinator?.stopObserving()
    }

    /// Records this session's module-graph teardown before it can yield, so an
    /// on-demand activation that follows a project switch can join the same
    /// operation instead of racing a capability release.
    private func beginModuleRuntimeShutdown() {
        moduleSessionCoordinator?.beginShutdown()
    }

    /// Shuts down this session's module graph once, even when multiple
    /// lifecycle paths request cleanup at the same time.
    private func shutdownModuleRuntime() async {
        await moduleSessionCoordinator?.shutdown()
    }

    /// Lets an on-demand activation resume after a session teardown finishes.
    ///
    /// A shutdown that starts while this wait is suspended is joined as well, so
    /// activation never returns a capability the runtime is about to release.
    func awaitModuleRuntimeShutdown() async {
        await moduleSessionCoordinator?.awaitShutdown()
    }

    private func reloadJavaRuntimeServices() {
        cancelJavaTestWorkflows()
        debugModuleCoordinator.stopFeature(genericDebugFeatureIfActive)
        executionModuleCoordinator.stopFeatures(
            maven: mavenFeatureIfActive,
            run: runFeatureIfActive
        )
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
        languageIntelligenceModuleCoordinator.prepareForRestart(
            feature: languageToolingFeature,
            sessions: languageToolingSessionsIfActive
        )
        cancelJavaLanguageServerPreparation()
        let didStart = activateCurrentDocumentLanguageServerIfAvailable()
        showNotification(
            didStart
                ? (settings.language == .simplifiedChinese ? "语言服务器已启动" : "Language server started")
                : (settings.language == .simplifiedChinese ? "当前没有运行中的 LSP 会话" : "No LSP session is running")
        )
    }

    func clearLanguageServerDiagnostics() {
        languageIntelligenceModuleCoordinator.clearDiagnostics(languageToolingSessionsIfActive)
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
        workspaceSessionCoordinator.openWorkspace(at: url)
    }

    private func prepareForWorkspaceOpen(at normalizedURL: URL) {
        documentLanguageCoordinator?.stop()
        beginModuleRuntimeShutdown()
        // A workspace root is a hard language-server ownership boundary. Stop
        // every provider session before replacing the catalog or clearing the
        // document projection so no old-root documents, diagnostics, or
        // responses can survive into the next workspace.
        cancelJavaWorkspaceWorkflows()
        languageToolingSessionsIfActive?.stopAll()
        reloadLanguageProviderCatalog(for: normalizedURL)
        stopTerminalSessions()
        executionModuleCoordinator.resetTests(languageTestServiceIfActive)
        languageIntelligenceModuleCoordinator.resetWorkspaceState(languageToolingFeature)
        runtimeFeature.openProject(at: normalizedURL)
        executionModuleCoordinator.resetFeatures(
            maven: mavenFeatureIfActive,
            run: runFeatureIfActive,
            tests: languageTestServiceIfActive
        )
        runWorkflowCoordinator.resetPendingAction()
        debugModuleCoordinator.resetFeature(genericDebugFeatureIfActive)
        debugBreakpointPresentation.reset()
        clearLanguageNavigationProjection()
        javaFeature.stop()
        springFeature.reset()
        workspaceSessionCoordinator.resetWorkspaceFeature()
        searchModuleCoordinator.resetFeature(searchFeatureIfActive)
        workbenchFeature.hideAllToolWindows()
        editorChrome.reset()
        editorDiagnosticsStore.reset()
        editorNavigationTarget = nil
        navigationHistoryFeature.reset()
        virtualDocumentProviderIDs.removeAll()
        blameVisibleURL = nil
        gitModuleCoordinator.resetFeature(gitFeatureIfActive)
        featureGraph.editorSession.resetContent()
        historyModuleCoordinator.resetFeature(projectHistoryFeatureIfActive)
        selectedSidebar = .project
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
    }

    func resumeGitObservationAfterActivation() async {
        await workspaceFeature.resumeObservationAfterActivation()
    }

    func closeProject() {
        workspaceSessionCoordinator.requestCloseWorkspace()
    }

    func closeStandaloneFile() {
        workspaceSessionCoordinator.requestCloseStandaloneFile()
    }

    private func finishWorkspaceClose(for workspaceURL: URL) {
        documentLanguageCoordinator?.stop()
        cancelJavaLanguageServerPreparation()
        beginModuleRuntimeShutdown()
        reloadLanguageProviderCatalog(for: nil)
        selectedSidebar = .project
        workspaceSessionCoordinator.resetWorkspaceFeature()
        featureGraph.editorSession.resetContent()
        searchModuleCoordinator.resetFeature(searchFeatureIfActive)
        searchSessionFeature.reset()
        editorChrome.resetFindBar()
        editorDiagnosticsStore.reset()
        historyModuleCoordinator.resetFeature(projectHistoryFeatureIfActive)
        workspaceSessionCoordinator.resetWorkspaceFeature()
        gitModuleCoordinator.resetFeature(gitFeatureIfActive)
        workbenchFeature.hideAllToolWindows()
        stopTerminalSessions()
        cancelJavaWorkspaceWorkflows()
        languageToolingSessionsIfActive?.stopAll()
        executionModuleCoordinator.resetTests(languageTestServiceIfActive)
        runtimeFeature.closeProject()
        executionModuleCoordinator.resetFeatures(
            maven: mavenFeatureIfActive,
            run: runFeatureIfActive,
            tests: languageTestServiceIfActive
        )
        runWorkflowCoordinator.resetPendingAction()
        debugModuleCoordinator.resetFeature(genericDebugFeatureIfActive)
        debugBreakpointPresentation.reset()
        javaFeature.stop()
        springFeature.reset()
        editorChrome.reset()
        editorNavigationTarget = nil
        navigationHistoryFeature.reset()
        virtualDocumentProviderIDs.removeAll()
        blameVisibleURL = nil
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        refreshRecentProjects()
        didCloseProject?()
    }

    private func prepareForStandaloneOpen(at normalizedURL: URL) {
        documentLanguageCoordinator?.stop()
        featureGraph.editorSession.resetContent()
        isFindBarVisible = false
        findBarQuery = ""
        if let mediaKind = MediaDocumentKind.from(url: normalizedURL) {
            openMediaFile(normalizedURL, kind: mediaKind)
        } else {
            documentFeature.openStandaloneFile(normalizedURL)
        }
    }

    private func finishStandaloneClose() {
        documentLanguageCoordinator?.stop()
        featureGraph.editorSession.resetContent()
        editorChrome.resetFindBar()
        editorChrome.setGoToLineVisible(false)
        didCloseProject?()
    }

    func removeRecentProject(_ project: RecentProject) {
        workspaceSessionCoordinator.removeRecentProject(project)
    }

    func refreshRecentProjects() {
        workspaceSessionCoordinator.refreshRecentProjects()
    }

    func loadWorkbenchLayout(for workspaceURL: URL) -> WorkbenchLayout {
        workbenchFeature.loadLayout(for: workspaceURL)
    }

    func saveWorkbenchLayout(_ layout: WorkbenchLayout, for workspaceURL: URL) {
        workbenchFeature.saveLayout(layout, for: workspaceURL)
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
        workspaceSessionCoordinator.openStandaloneFile(at: url)
    }

    func javaIconKind(for url: URL) async -> LitheIconKind? {
        await JavaFileIconResolver.resolve(for: url, storage: services.fileStorage)
    }

    func refreshWorkspace() async {
        await workspaceFeature.refreshCurrent()
    }

    func markProjectDirectory(_ url: URL, as mark: WorkspaceDirectoryMark) async {
        await workspaceFeature.markDirectory(url, as: mark)
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
        workspaceSessionCoordinator.cancelPendingClose()
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
                rootURL: workspaceURL,
                changes: document.takePendingLanguageServerChanges()
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
        await commitWorkflow.commit()
    }

    func commitAndPushStagedChanges() async {
        await commitWorkflow.commit(push: true)
    }

    func generateCommitMessage() async {
        await commitWorkflow.generateMessage()
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
        commitWorkflow.applyGeneratedMessage()
    }

    func discardPendingGeneratedCommitMessage() {
        commitDraftFeature.discardGeneratedMessage()
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
            workbenchFeature.setVisibility(.gitLog, isVisible: true)
        }
        if isGitLogVisible && gitCommits.isEmpty {
            await refreshGitHistory()
        } else if !isGitLogVisible {
            gitFeatureIfActive?.cancelGitHistoryLoading()
        }
    }

    func closeGitLog() {
        workbenchFeature.setVisibility(.gitLog, isVisible: false)
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
        workbenchFeature.setVisibility(.gitLog, isVisible: true)
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

    func deleteBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.deleteBranch(reference)
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

    func fetchGit() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.fetchGit()
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

    func pushBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.pushBranch(reference)
    }

}
