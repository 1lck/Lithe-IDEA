import Combine
import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case project = "Project"
    case general = "General"
    case editor = "Editor"
    case terminal = "Terminal"
    case ai = "AI & Commit"
    case updates = "Updates"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .project: "folder.badge.gearshape"
        case .general: "gearshape"
        case .editor: "textformat"
        case .terminal: "terminal"
        case .ai: "wand.and.stars"
        case .updates: "arrow.down.circle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var workspaceURL: URL?
    @Published var selectedSidebar: SidebarDestination = .project
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
    @Published private(set) var searchSidebarFocusRequest = 0
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
    @Published private(set) var detectedAIConfigurations: [AIConfigurationSnapshot] = []
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
    @Published var isLSPControlCenterVisible = true
    @Published var isImplementationChooserVisible = false
    @Published private(set) var languageProviderCatalog: LanguageProviderCatalog
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
    private let services: AppServices
    private let platformUI: any PlatformUI
    let settings: AppSettings
    let runtimeFeature: RuntimeSettingsFeatureModel
    let mavenFeature: MavenFeatureModel
    let runFeature: RunFeatureModel
    let projectDevelopmentFeature: ProjectDevelopmentFeatureModel
    let debugFeature: JavaDebugFeatureModel
    let genericDebugFeature: GenericDebugFeatureModel
    let debugLaunchConfigurationResolver: DebugLaunchConfigurationResolver
    let workspaceFeature: WorkspaceFeatureModel
    let searchFeature: SearchFeatureModel
    let terminalFeature: TerminalFeatureModel
    let projectHistoryFeature: ProjectHistoryFeatureModel
    let gitFeature: GitFeatureModel
    let documentFeature: DocumentFeatureModel
    let javaFeature: JavaFeatureModel
    var workspaceFileOperations: any WorkspaceFileOperations { services.fileOperations }
    var languageToolingSessions: LanguageToolingSessionManager { services.languageToolingSessions }
    var languageServerTools: LanguageServerToolService { services.languageServerTools }
    var languageTestService: LanguageTestService { services.languageTestService }
    var languageDiagnostics: [URL: [LanguageServerDiagnostic]] {
        languageToolingSessions.diagnostics
    }
    var editorDiagnostics: [URL: [EditorDiagnostic]] {
        EditorDiagnostic.merging(
            javaDiagnostics,
            languageServerDiagnostics: languageDiagnostics
        )
    }
    private var workspaceFeatureObservation: AnyCancellable?
    private var runtimeFeatureObservation: AnyCancellable?
    private var searchFeatureObservation: AnyCancellable?
    private var terminalFeatureObservation: AnyCancellable?
    private var projectHistoryFeatureObservation: AnyCancellable?

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
        languageToolingSessions.stopLanguageServer(providerID: providerID)
    }
    private var gitFeatureObservation: AnyCancellable?
    private var documentFeatureObservation: AnyCancellable?
    private var javaFeatureObservation: AnyCancellable?
    private var languageToolingObservation: AnyCancellable?
    private var languageTestObservation: AnyCancellable?
    private var recentProjectsStore: RecentProjectsStore { services.recentProjectsStore }
    private var workbenchLayoutStore: WorkbenchLayoutStore { services.workbenchLayoutStore }

    init(settings: AppSettings, services: AppServices) {
        self.settings = settings
        self.services = services
        languageProviderCatalog = services.languageProviderCatalog
        platformUI = services.platformUI
        workspaceFeature = WorkspaceFeatureModel(
            operations: services.workspaceOperations,
            fileOperations: services.fileOperations,
            directoryWatcherFactory: services.directoryWatcherFactory,
            workspaceSessionStore: services.workspaceSessionStore
        )
        searchFeature = SearchFeatureModel(operations: services.workspaceOperations)
        runtimeFeature = RuntimeSettingsFeatureModel(service: services.projectRuntimeService)
        mavenFeature = MavenFeatureModel(service: services.mavenService)
        runFeature = RunFeatureModel(service: services.runService)
        projectDevelopmentFeature = ProjectDevelopmentFeatureModel(
            mavenFeature: mavenFeature,
            runFeature: runFeature
        )
        debugFeature = JavaDebugFeatureModel(service: services.javaDebugService)
        genericDebugFeature = GenericDebugFeatureModel(sessions: services.languageToolingSessions)
        debugLaunchConfigurationResolver = services.debugLaunchConfigurationResolver
        terminalFeature = TerminalFeatureModel(terminalFactory: services.terminalFactory)
        projectHistoryFeature = ProjectHistoryFeatureModel(
            workspaceOperations: services.workspaceOperations,
            fileOperations: services.fileOperations,
            fileStorage: services.fileStorage,
            localHistoryOperations: services.localHistoryOperations
        )
        gitFeature = GitFeatureModel(
            service: services.gitService,
            shelveService: services.shelveService
        )
        documentFeature = DocumentFeatureModel(
            operations: services.workspaceOperations,
            fileOperations: services.fileOperations
        )
        javaFeature = JavaFeatureModel(
            markerService: services.javaImplementationMarkerService,
            operations: services.javaMavenOperations,
            workspaceOperations: services.workspaceOperations
        )
        javaFeature.configureRuntime(
            mavenFeature: mavenFeature,
            debugFeature: debugFeature
        )
        recentProjects = services.recentProjectsStore.load()
        workspaceFeatureObservation = workspaceFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        runtimeFeatureObservation = runtimeFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        searchFeatureObservation = searchFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        terminalFeatureObservation = terminalFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        languageToolingObservation = services.languageToolingSessions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        languageTestObservation = services.languageTestService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        projectHistoryFeature.configure(
            workspaceURLProvider: { [weak self] in self?.workspaceURL },
            projectFilesProvider: { [weak self] in self?.projectFiles ?? [] },
            documentsProvider: { [weak self] in self?.openDocuments ?? [] }
        )
        workspaceFeature.configure(
            documentsProvider: { [weak self] in self?.openDocuments ?? [] },
            activeDocumentProvider: { [weak self] in self?.activeDocument },
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
                await self?.projectHistoryFeature.recordHistory(containedIn: url, reason: reason)
            },
            relocateHistory: { [weak self] source, destination in
                await self?.projectHistoryFeature.relocateHistory(from: source, to: destination)
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
                self.projectHistoryFeature.recordExternalChanges(paths)
                return conflict
            },
            reloadProjectServices: { [weak self] in
                guard let self, let workspaceURL = self.workspaceURL else { return }
                await self.loadProjectServices(at: workspaceURL, files: self.projectFiles)
            },
            refreshGit: { [weak self] in await self?.refreshGit() },
            updateHistoryVisibilityRules: { [weak self] rules in
                await self?.projectHistoryFeature.updateVisibilityRules(rules)
            },
            onSnapshotLoaded: { [weak self] snapshot, isInitialLoad in
                guard let self, let workspaceURL = self.workspaceURL else { return }
                await self.refreshGit()
                await self.loadProjectServices(at: workspaceURL, files: snapshot.files)
                if isInitialLoad {
                    self.projectHistoryFeature.seed(files: snapshot.files)
                }
            }
        )
        projectHistoryFeatureObservation = projectHistoryFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        gitFeature.configure(
            workspaceURLProvider: { [weak self] in self?.workspaceURL },
            isGitLogVisibleProvider: { [weak self] in self?.isGitLogVisible ?? false },
            notify: { [weak self] message in self?.showNotification(message) },
            onStateRefreshed: { [weak self] in
                guard let self, let document = self.activeDocument else { return }
                await self.refreshCodeVision(for: document.url)
            },
            saveChangesPolicy: { [weak self] in self?.settings.gitSaveChangesPolicy ?? .stash },
            onGitOperationBegan: { [weak self] in
                self?.workspaceFeature.beginGitOperationFreeze()
            },
            onGitOperationEnded: { [weak self] in
                await self?.workspaceFeature.endGitOperationFreeze()
            }
        )
        gitFeatureObservation = gitFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
                self?.projectHistoryFeature.recordExternalChanges(paths)
            },
            onDocumentCollectionChanged: { [weak self] in
                self?.workspaceFeature.scheduleWorkspaceSessionPersistence()
            },
            onProjectCloseReady: { [weak self] in
                self?.performCloseProject()
            }
        )
        documentFeatureObservation = documentFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        javaFeature.configure(
            documentProvider: { [weak self] in self?.activeDocument },
            caretProvider: { [weak self] in self?.editorCaret },
            notify: { [weak self] message in self?.showNotification(message) },
            loadBlame: { [weak self] fileURL in
                guard let self else { return [] }
                return await self.gitFeature.loadBlame(for: fileURL)
            }
        )
        javaFeatureObservation = javaFeature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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
        runtimeFeature.setOnRuntimeChanged { [weak self] in
            self?.reloadJavaRuntimeServices()
        }
        doubleShiftDetector = services.shortcutDetectorFactory.make { [weak self] in
            self?.toggleSearchEverywhere()
        }
        doubleShiftDetector?.start()
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
        languageToolingSessions.stopAll()
        languageTestService.stop()
        stopTerminalSessions()
        if let fileVisibilityRulesObserverID {
            settings.removeFileVisibilityRulesObserver(fileVisibilityRulesObserverID)
            self.fileVisibilityRulesObserverID = nil
        }
    }

    private func reloadJavaRuntimeServices() {
        debugFeature.stop()
        mavenFeature.stop()
        languageToolingSessions.stopLanguageServer(providerID: "java")
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
        languageTestService.discover(workspaceURL: workspaceURL, files: files)
        await projectDevelopmentFeature.loadProject(at: workspaceURL, files: files)
    }

    var projectName: String {
        workspaceURL?.lastPathComponent ?? "Lithe"
    }

    var languageServerStatusMessage: String {
        let usesChinese = settings.language == .simplifiedChinese
        if isLoadingLanguageNavigation {
            return usesChinese ? "正在加载语言导航..." : "Loading language navigation..."
        }
        if languageNavigationProviderID != nil {
            return usesChinese ? "语言服务器已就绪" : "Language server ready"
        }
        if let document = activeDocument,
           let descriptor = languageProviderCatalog.provider(for: document.url),
            descriptor.capabilities.contains(.languageServer) {
            if languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id) {
                return usesChinese
                    ? "\(descriptor.displayName) 语言服务器已就绪"
                    : "\(descriptor.displayName) language server ready"
            }
            return usesChinese
                ? "\(descriptor.displayName) 语言服务器可按需启动"
                : "\(descriptor.displayName) language server available on demand"
        }
        return usesChinese ? "打开一个受支持的源码文件" : "Open a supported source file"
    }

    func restartLanguageServers() {
        languageToolingSessions.stopAllLanguageServers()
        if let activeDocument {
            activateLanguageServerIfAvailable(for: activeDocument)
        }
        showNotification(settings.language == .simplifiedChinese ? "语言服务器已重启" : "Language servers restarted")
    }

    func clearLanguageServerDiagnostics() {
        languageToolingSessions.clearDiagnostics()
        showNotification(settings.language == .simplifiedChinese ? "语言服务器诊断已清空" : "Language server diagnostics cleared")
    }

    func implementationMarkers(
        for document: EditorDocument,
        candidates: [JavaImplementationMarker]
    ) async -> [JavaImplementationMarker] {
        await javaFeature.implementationMarkers(for: document, candidates: candidates)
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
        if let previousWorkspaceURL = workspaceURL {
            workspaceFeature.persistWorkspaceSession(for: previousWorkspaceURL)
        }
        reloadLanguageProviderCatalog(for: normalizedURL)
        stopTerminalSessions()
        languageTestService.reset()
        runtimeFeature.openProject(at: normalizedURL)
        mavenFeature.reset()
        runFeature.reset()
        debugFeature.reset()
        genericDebugFeature.reset()
        clearLanguageNavigationProjection()
        javaFeature.stop()
        workspaceFeature.reset()
        searchFeature.reset()
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
        gitFeature.reset()
        documentFeature.reset()
        gitLogSearchQuery = ""
        projectHistoryFeature.reset()
        workspaceURL = normalizedURL
        let visibilityRules = settings.fileVisibilityRules
        projectHistoryFeature.openWorkspace(at: normalizedURL, visibilityRules: visibilityRules)
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

    func closeProject() {
        guard workspaceURL != nil else { return }
        guard documentFeature.beginProjectClose() else {
            performCloseProject()
            return
        }
    }

    private func performCloseProject() {
        if let workspaceURL {
            workspaceFeature.persistWorkspaceSession(for: workspaceURL)
        }
        workspaceURL = nil
        reloadLanguageProviderCatalog(for: nil)
        selectedSidebar = .project
        workspaceFeature.reset()
        documentFeature.reset()
        searchFeature.reset()
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
        projectHistoryFeature.reset()
        workspaceFeature.reset()
        gitFeature.reset()
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isTestsVisible = false
        isDebugVisible = false
        stopTerminalSessions()
        languageToolingSessions.stopAll()
        languageTestService.reset()
        runtimeFeature.closeProject()
        mavenFeature.reset()
        runFeature.reset()
        debugFeature.reset()
        genericDebugFeature.reset()
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
        let catalog = services.languageProviderCatalogSource.catalog(workspaceURL: workspaceURL)
        languageProviderCatalog = catalog
        languageToolingSessions.updateCatalog(catalog)
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
        projectHistoryFeature.showLocalHistory(for: fileURL)
    }

    func showProjectLocalHistory() {
        projectHistoryFeature.showProjectLocalHistory()
    }

    func selectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        projectHistoryFeature.selectLocalHistoryEntry(entry)
    }

    func selectProjectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        projectHistoryFeature.selectProjectLocalHistoryEntry(entry)
    }

    func refreshLocalHistory() async {
        await projectHistoryFeature.refreshLocalHistory()
    }

    func refreshProjectLocalHistory() async {
        await projectHistoryFeature.refreshProjectLocalHistory()
    }

    func restoreSelectedLocalHistoryEntry() async {
        guard let restoration = await projectHistoryFeature.restoreSelectedLocalHistoryEntry() else {
            showNotification("Could not restore local history")
            return
        }
        if let documentID = restoration.documentID {
            activeDocumentID = documentID
        } else {
            openFile(restoration.url)
        }
        showNotification("Restored \(restoration.url.lastPathComponent)")
        await refreshWorkspace()
        await projectHistoryFeature.refreshLocalHistory()
    }

    func restoreSelectedProjectLocalHistoryEntry() async {
        guard let restoration = await projectHistoryFeature.restoreSelectedProjectLocalHistoryEntry() else {
            showNotification("Could not restore project history")
            return
        }
        if let documentID = restoration.documentID {
            activeDocumentID = documentID
        }
        showNotification("Restored \(restoration.url.lastPathComponent)")
        await refreshWorkspace()
        await projectHistoryFeature.refreshProjectLocalHistory()
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

    private func workspaceRelativePath(for url: URL, root: URL) -> String? {
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
        languageToolingSessions.closeDocument(document.url)
        if javaFeature.handles(fileURL: document.url) {
            javaFeature.close(document)
        }
    }

    private func activateLanguageServerIfAvailable(for document: EditorDocument) {
        guard let workspaceURL,
              languageProviderCatalog.provider(for: document.url) != nil else { return }
        try? languageToolingSessions.synchronizeLanguageServer(
            for: document.url,
            text: document.text,
            rootURL: workspaceURL
        )
    }

    func searchProject(options: ProjectSearchOptions = .default) async {
        guard let workspaceURL else { return }
        let query = searchQuery
        await searchFeature.searchProject(
            at: workspaceURL,
            query: query,
            options: options,
            visibilityRules: settings.fileVisibilityRules,
            isCurrent: { [weak self] in
                self?.workspaceURL == workspaceURL && self?.searchQuery == query
            }
        )
    }

    func toggleSearchEverywhere() {
        guard workspaceURL != nil else { return }
        // 弹窗已打开时忽略再次双击 Shift：避免输入大写字母等场景误触关闭。
        guard !isSearchEverywhereVisible else { return }
        isSearchEverywhereVisible = true
    }

    func dismissSearchEverywhere() {
        isSearchEverywhereVisible = false
        searchEverywhereQuery = ""
        searchFeature.clearSearchEverywhere()
    }

    func searchEverywhere(options: ProjectSearchOptions = .default) async {
        guard let workspaceURL else {
            searchFeature.clearSearchEverywhere()
            return
        }
        let query = searchEverywhereQuery
        let actionMatches = LitheActionRegistry.actions(for: self).filter { $0.matches(query) }
        await searchFeature.searchEverywhere(
            at: workspaceURL,
            query: query,
            options: options,
            visibilityRules: settings.fileVisibilityRules,
            actionMatches: actionMatches,
            isCurrent: { [weak self] in
                self?.workspaceURL == workspaceURL && self?.searchEverywhereQuery == query
            }
        )
    }

    /// Find in Files：切到搜索侧栏，预填当前选区并把焦点交给输入框。
    func openProjectSearch() {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty {
            searchQuery = editorSelectedText
        }
        selectedSidebar = .search
        searchSidebarFocusRequest += 1
    }

    func clearProjectReplacementPreview() {
        searchFeature.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
    }

    /// 打开 Replace in Project。传入侧栏当前选项可让查询条件延续，避免重填。
    func openProjectReplace(inheriting options: ProjectSearchOptions? = nil) {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty {
            searchQuery = editorSelectedText
        }
        projectReplaceQuery = searchQuery
        projectReplaceText = ""
        if let options {
            projectReplaceOptions = options
        }
        searchFeature.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
        isProjectReplaceVisible = true
    }

    func previewProjectReplacement() async {
        guard let rootURL = workspaceURL else { return }
        let query = projectReplaceQuery
        let rules = settings.fileVisibilityRules
        let replacement = projectReplaceText
        let paths = projectFiles.compactMap { workspaceRelativePath(for: $0, root: rootURL) }
        let overrides: [String: String] = Dictionary(uniqueKeysWithValues: openDocuments.compactMap { document in
            guard let path = workspaceRelativePath(for: document.url, root: rootURL) else { return nil }
            return (path, document.text)
        })
        await searchFeature.previewProjectReplacement(
            at: rootURL,
            query: query,
            replacement: replacement,
            paths: paths,
            textOverrides: overrides,
            options: projectReplaceOptions,
            visibilityRules: rules,
            isCurrent: { [weak self] in
                self?.workspaceURL == rootURL && self?.projectReplaceQuery == query
            }
        )
        guard projectReplaceQuery == query else { return }
        selectedProjectReplacementPaths = Set(projectReplacementFiles.map(\.relativePath))
    }

    func applyProjectReplacement() async {
        guard self.workspaceURL != nil,
              !projectReplaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let selectedPaths = selectedProjectReplacementPaths
        guard let rootURL = workspaceURL else { return }
        let result = await searchFeature.applyProjectReplacement(
            at: rootURL,
            selectedPaths: selectedPaths,
            documents: openDocuments,
            recordHistory: { [weak self] text, fileURL in
                await self?.projectHistoryFeature.recordHistorySnapshot(
                    text: text,
                    for: fileURL,
                    reason: .beforeBatchReplace
                )
            },
            saveDocument: { [weak self] document in
                try self?.saveDocument(document)
            }
        )
        isProjectReplaceVisible = false
        searchFeature.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
        await refreshWorkspace()
        if !result.failedFiles.isEmpty {
            showNotification("Could not replace in \(result.failedFiles.count) file(s)")
        } else if result.changedFiles > 0 {
            showNotification("Replaced text in \(result.changedFiles) file(s)")
        }

    }

    func openSearchEverywhereResult(_ result: FileSearchResult) {
        dismissSearchEverywhere()
        openSearchResult(result)
    }

    func performSearchEverywhereAction(_ action: LitheAction) {
        dismissSearchEverywhere()
        action.perform()
    }

    func openSearchResult(_ result: FileSearchResult) {
        openFile(result.url)
        if let line = result.line {
            editorNavigationTarget = EditorNavigationTarget(
                url: result.url,
                line: line - 1,
                utf16Column: 0
            )
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
        Task { await gitFeature.selectChange(change) }
    }

    func reloadSelectedChangeDiff(whitespace: GitDiffWhitespaceMode) async {
        await gitFeature.reloadSelectedChangeDiff(whitespace: whitespace)
    }

    func refreshGit() async {
        await gitFeature.refreshGit()
    }

    func stageSelectedChange() async {
        await gitFeature.stageSelectedChange()
    }

    func unstageSelectedChange() async {
        await gitFeature.unstageSelectedChange()
    }

    func stageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        await gitFeature.stageDiffHunk(hunk, in: change)
    }

    func unstageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        await gitFeature.unstageDiffHunk(hunk, in: change)
    }

    func requestDiscardHunk(_ hunk: DiffHunk, in change: GitChange) {
        gitFeature.requestDiscardHunk(hunk, in: change)
    }

    func confirmDiscardHunk() async {
        await gitFeature.confirmDiscardHunk()
    }

    func cancelDiscardHunk() {
        gitFeature.cancelDiscardHunk()
    }

    func requestDiscardSelectedChange() {
        gitFeature.requestDiscardSelectedChange()
    }

    func requestDiscardChange(_ change: GitChange) {
        gitFeature.requestDiscardChange(change)
    }

    func confirmDiscardChange() async {
        await gitFeature.confirmDiscardChange()
    }

    func cancelDiscardChange() {
        gitFeature.cancelDiscardChange()
    }

    func commitStagedChanges() async {
        if await gitFeature.commitStagedChanges(message: commitMessage, amend: amendCommit) {
            commitMessage = ""
            amendCommit = false
        }
    }

    func commitAndPushStagedChanges() async {
        if await gitFeature.commitAndPushStagedChanges(message: commitMessage, amend: amendCommit) {
            commitMessage = ""
            amendCommit = false
        }
    }

    func generateCommitMessage() async {
        guard !isGeneratingCommitMessage else { return }
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
            let generated = try await services.commitMessageGenerator.generate(
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

    @discardableResult
    func refreshAIConfigurations() -> Bool {
        let configurations = loadAIConfigurations()
        detectedAIConfigurations = configurations

        guard let activeProvider = settings.activeCommitMessageProvider,
              let source = configurationSource(for: activeProvider),
              let configuration = configurations.first(where: { $0.source == source }) else {
            return !configurations.isEmpty
        }

        updateImportedProvider(from: configuration)
        return true
    }

    @discardableResult
    func refreshCodexConfiguration() -> Bool {
        refreshAIConfigurations()
        return detectedCodexConfiguration != nil
    }

    @discardableResult
    func importAIConfiguration(_ configuration: AIConfigurationSnapshot) -> Bool {
        let provider = settings.importAIConfiguration(configuration)
        try? services.secureStore.delete(key: provider.apiKeyIdentifier)
        detectedAIConfigurations.removeAll { $0.source == configuration.source }
        detectedAIConfigurations.append(configuration)
        showNotification("\(configuration.source.title) configuration imported")
        return true
    }

    @discardableResult
    func importCodexConfiguration() -> Bool {
        guard let codexConfiguration = loadAIConfigurations().first(where: { $0.source == .codex }) else {
            detectedAIConfigurations.removeAll { $0.source == .codex }
            showNotification("No Codex configuration was found")
            return false
        }
        return importAIConfiguration(codexConfiguration)
    }

    var activeCommitMessageAPIKey: String {
        guard let provider = settings.activeCommitMessageProvider else { return "" }
        return services.credentialResolver.readAPIKey(for: provider) ?? ""
    }

    var activeCommitMessageCredentialIsConfigurationManaged: Bool {
        guard let provider = settings.activeCommitMessageProvider else { return false }
        return configurationSource(for: provider) != nil
    }

    var activeCommitMessageConfigurationSourceTitle: String? {
        settings.activeCommitMessageProvider
            .flatMap(configurationSource(for:))?
            .title
    }

    var activeCommitMessageConfigurationSourceDescription: String? {
        settings.activeCommitMessageProvider
            .flatMap(configurationSource(for:))?
            .settingsDescription
    }

    var activeCommitMessageCredentialIsCodexManaged: Bool {
        activeCommitMessageCredentialIsConfigurationManaged
    }

    func saveActiveCommitMessageAPIKey(_ value: String) {
        guard let provider = settings.activeCommitMessageProvider else { return }
        if activeCommitMessageCredentialIsConfigurationManaged {
            let source = activeCommitMessageConfigurationSourceTitle ?? "AI"
            showNotification("API key is managed by \(source) configuration")
            return
        }
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try services.secureStore.delete(key: provider.apiKeyIdentifier)
            } else {
                try services.secureStore.write(trimmed, key: provider.apiKeyIdentifier)
            }
            showNotification("API key saved locally")
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    private func loadAIConfigurations() -> [AIConfigurationSnapshot] {
        services.aiConfigurationSources.compactMap { $0.load() }
    }

    private func configurationSource(
        for provider: AIProviderProfile
    ) -> AIConfigurationSourceKind? {
        if let source = provider.credentialSource.configurationSource {
            return source
        }
        if provider.apiKeyIdentifier == "lithe.codex.imported.apiKey" {
            return .codex
        }
        if provider.apiKeyIdentifier == "lithe.claude.imported.apiKey" {
            return .claude
        }
        return nil
    }

    private func updateImportedProvider(from configuration: AIConfigurationSnapshot) {
        guard let activeProvider = settings.activeCommitMessageProvider,
              configurationSource(for: activeProvider) == configuration.source else {
            return
        }

        settings.updateActiveCommitMessageProvider { provider in
            provider.name = configuration.providerName.isEmpty
                ? "\(configuration.source.title) (imported)"
                : "\(configuration.source.title) · \(configuration.providerName)"
            provider.endpoint = configuration.endpoint
            provider.model = configuration.model
            provider.apiProtocol = configuration.apiProtocol
            provider.authentication = configuration.authentication
            provider.requiresAPIKey = configuration.requiresAPIKey
            provider.apiKeyIdentifier = "lithe.\(configuration.source.rawValue).imported.apiKey"
            provider.credentialSource = configuration.source.credentialSource
        }
        try? services.secureStore.delete(
            key: "lithe.\(configuration.source.rawValue).imported.apiKey"
        )
    }

    func toggleStaging(_ change: GitChange) async {
        await gitFeature.toggleStaging(change)
    }

    func stageAllChanges() async {
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

    func toggleTerminal() {
        isTerminalVisible.toggle()
        guard isTerminalVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        if activeTerminalSession == nil {
            createTerminalSession()
        }
    }

    var terminalSessions: [TerminalSession] {
        terminalFeature.terminalSessions
    }

    var activeTerminalSessionID: UUID? {
        terminalFeature.activeTerminalSessionID
    }

    var activeTerminalSession: TerminalSession? {
        terminalFeature.activeTerminalSession
    }

    func terminalTitle(for session: TerminalSession) -> String {
        terminalFeature.terminalTitle(for: session)
    }

    @discardableResult
    func createTerminalSession(shellPath: String? = nil) -> TerminalSession? {
        guard let workspaceURL else { return nil }
        let session = terminalFeature.createSession(
            in: workspaceURL,
            shellPath: shellPath ?? settings.terminalShellPath
        )
        configureTerminalSession(session)
        isTerminalVisible = true
        isTestsVisible = false
        isGitLogVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        return session
    }

    private func configureTerminalSession(_ session: TerminalSession) {
        let sessionID = session.id
        session.onLink = { [weak self] link, params in
            self?.openTerminalLink(link, params: params, sessionID: sessionID)
        }
    }

    private func openTerminalLink(
        _ link: String,
        params: [String: String],
        sessionID: UUID
    ) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }),
              let fallbackDirectory = session.currentDirectory ?? workspaceURL else {
            return
        }

        switch TerminalLinkResolver.resolve(
            link,
            relativeTo: fallbackDirectory,
            fileExists: { [services] in services.fileStorage.fileExists(at: $0) }
        ) {
        case .file(let location):
            guard let workspaceURL else {
                platformUI.open(location.url)
                return
            }
            if isFile(location.url, inside: workspaceURL) {
                openSourceLocation(
                    url: location.url,
                    line: location.line ?? 1,
                    column: location.column
                )
            } else {
                platformUI.open(location.url)
            }
        case .external(let url):
            platformUI.open(url)
        case nil:
            return
        }
    }

    private func isFile(_ fileURL: URL, inside directoryURL: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let directoryPath = directoryURL.standardizedFileURL.path
        guard filePath != directoryPath else { return true }
        return filePath.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/")
    }

    func selectTerminalSession(_ session: TerminalSession) {
        guard terminalFeature.selectSession(session) else { return }
        isTerminalVisible = true
    }

    func closeTerminalSession(_ session: TerminalSession) {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return }
        terminalFeature.closeSession(session)
        if terminalSessions.isEmpty {
            isTerminalVisible = false
        }
    }

    func restartActiveTerminal() {
        terminalFeature.restartActiveSession()
    }

    func restartActiveTerminal(using shellPath: String) {
        terminalFeature.restartActiveSession(using: shellPath)
    }

    func stopTerminalSessions() {
        terminalFeature.stopAllSessions()
    }

    func closeGitLog() {
        isGitLogVisible = false
    }

    func selectGitReference(_ reference: GitReference?) async {
        await gitFeature.selectGitReference(reference)
    }

    func refreshGitHistory() async {
        await gitFeature.refreshGitHistory()
    }

    func loadMoreGitHistory() async {
        await gitFeature.loadMoreGitHistory()
    }

    func selectGitCommit(_ commit: GitCommit) async {
        await gitFeature.selectGitCommit(commit)
    }

    func showGitCommitDiff(for file: GitCommitFile) {
        activeDocumentID = nil
        Task { await gitFeature.showGitCommitDiff(for: file) }
    }

    func closeGitCommitDiff() {
        gitFeature.closeGitCommitDiff()
    }

    func refreshCodeVision(for fileURL: URL) async {
        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.pathExtension.lowercased() == "java",
              let document = openDocuments.first(where: { $0.url.standardizedFileURL == normalizedURL }),
              !document.isReadOnly,
              let workspaceRoot = workspaceURL else { return }
        await javaFeature.refreshCodeVision(
            for: document,
            projectFiles: projectFiles,
            workspaceRoot: workspaceRoot
        )
    }

    func refreshJavaInlayHints(for document: EditorDocument) {
        javaFeature.refreshInlayHints(
            for: document,
            projectFiles: projectFiles,
            workspaceRoot: workspaceURL
        )
    }

    func showBlame(for fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        blameVisibleURL = blameVisibleURL == normalizedURL ? nil : normalizedURL
    }

    func hideBlame() {
        blameVisibleURL = nil
    }

    func findUsages(for hint: JavaCodeVisionHint, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: hint.line,
            utf16Column: hint.utf16Column
        )
        findReferences()
    }

    func showGitCommit(_ hash: String) async {
        guard gitRepositoryRoot != nil, !hash.allSatisfy({ $0 == "0" }) else { return }
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
        await gitFeature.showComparisonWithWorkingTree(for: reference)
    }

    func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
        await gitFeature.selectBranchComparisonFile(file)
    }

    func closeBranchComparison() {
        gitFeature.closeBranchComparison()
    }

    func createBranch(
        named rawName: String,
        from reference: GitReference,
        checkout: Bool
    ) async {
        await gitFeature.createBranch(named: rawName, from: reference, checkout: checkout)
    }

    func renameBranch(_ reference: GitReference, to rawName: String) async {
        await gitFeature.renameBranch(reference, to: rawName)
    }

    func deleteBranch(_ reference: GitReference) async {
        await gitFeature.deleteBranch(reference)
    }

    func mergeBranch(_ reference: GitReference) async {
        await gitFeature.mergeBranch(reference)
    }

    func continueGitOperation() async {
        await gitFeature.continueGitOperation()
    }

    func resolvePullStrategy(_ strategy: GitPullStrategy) async {
        await gitFeature.resolvePullStrategy(strategy)
    }

    func cancelPullStrategy() {
        gitFeature.cancelPullStrategy()
    }

    func resolveIntegrationConflict(_ request: GitIntegrationConflictRequest) async {
        await gitFeature.resolveIntegrationConflict(request)
    }

    func cancelIntegrationConflict() {
        gitFeature.cancelIntegrationConflict()
    }

    func abortGitOperation() async {
        await gitFeature.abortGitOperation()
    }

    func skipGitOperationStep() async {
        await gitFeature.skipGitOperationStep()
    }

    func rebaseCurrentBranch(onto reference: GitReference) async {
        await gitFeature.rebaseCurrentBranch(onto: reference)
    }

    func updateCurrentBranch(_ reference: GitReference) async {
        await gitFeature.updateCurrentBranch(reference)
    }

    func fetchGit() async {
        await gitFeature.fetchGit()
    }

    func checkoutReference(_ reference: GitReference) async {
        await gitFeature.checkoutReference(reference)
    }

    func resolveCheckoutConflict(
        _ request: GitCheckoutConflictRequest,
        strategy: GitCheckoutConflictStrategy
    ) async {
        await gitFeature.resolveCheckoutConflict(request, strategy: strategy)
    }

    func checkoutRevision(_ rawRevision: String) async {
        await gitFeature.checkoutRevision(rawRevision)
    }

    func cherryPick(_ commit: GitCommit) async {
        await gitFeature.cherryPick(commit)
    }

    func revert(_ commit: GitCommit) async {
        await gitFeature.revert(commit)
    }

    func resetCurrentBranch(to commit: GitCommit) async {
        await gitFeature.resetCurrentBranch(to: commit)
    }

    func pushBranch(_ reference: GitReference) async {
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
        projectHistoryFeature.recordSave(document, previousText: previousText)
    }

    private func recordDiscardedEditorText(_ document: EditorDocument) {
        projectHistoryFeature.recordDiscardedEditorText(document)
    }
}

enum SidebarDestination: String, CaseIterable, Identifiable {
    case project
    case changes
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .changes: "Changes"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .project: "folder"
        case .changes: "slider.horizontal.3"
        case .search: "magnifyingglass"
        }
    }

    var ideaAssetPath: String {
        switch self {
        case .project: "toolwindows/toolWindowProject.svg"
        case .changes: "toolwindows/toolWindowCommit.svg"
        case .search: "toolwindows/toolWindowFind.svg"
        }
    }
}

enum ProjectItemEditKind: Sendable {
    case createFile
    case createDirectory
    case rename
}

struct ProjectItemEditRequest: Identifiable, Sendable {
    let id = UUID()
    let kind: ProjectItemEditKind
    let targetURL: URL
}

struct ProjectItemDeletionRequest: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
}

enum FindNotificationKeys {
    static let query = "query"
    static let direction = "direction"
}

extension Notification.Name {
    static let litheFindQueryChanged = Notification.Name("litheFindQueryChanged")
    static let litheFindNavigate = Notification.Name("litheFindNavigate")
    static let litheFindDismiss = Notification.Name("litheFindDismiss")
}
