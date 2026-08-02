import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published var selectedSidebar: SidebarDestination = .project
    @Published var isRunVisible = false
    @Published var isSettingsPresented = false
    @Published var isCloneRepositoryPresented = false
    @Published private(set) var isCloningRepository = false
    @Published private(set) var recentProjects: [RecentProject]
    @Published private(set) var rootNode: FileNode?
    @Published private(set) var projectFiles: [URL] = []
    @Published private(set) var openDocuments: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [FileSearchResult] = []
    @Published private(set) var isLoadingWorkspace = false
    @Published private(set) var isRefreshingWorkspace = false
    @Published private(set) var isSearching = false
    @Published var isSearchEverywhereVisible = false
    @Published var searchEverywhereQuery = ""
    @Published private(set) var searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
    @Published private(set) var isSearchingEverywhere = false
    @Published var isProjectReplaceVisible = false
    @Published var projectReplaceQuery = ""
    @Published var projectReplaceText = ""
    @Published private(set) var projectReplacementFiles: [ProjectReplacementFile] = []
    @Published var selectedProjectReplacementPaths: Set<String> = []
    @Published private(set) var isLoadingProjectReplacement = false
    @Published var isFindBarVisible = false
    @Published var findBarQuery = ""
    @Published private(set) var findMatchCount = 0
    @Published private(set) var currentFindMatchIndex = 0
    @Published var pendingCloseDocument: EditorDocument?
    @Published var projectItemEditRequest: ProjectItemEditRequest?
    @Published var pendingProjectItemDeletion: ProjectItemDeletionRequest?
    @Published private(set) var isPerformingProjectItemOperation = false
    @Published var notificationMessage: String?
    @Published var localHistoryRequest: LocalHistoryRequest?
    @Published private(set) var localHistoryEntries: [LocalHistoryEntry] = []
    @Published var selectedLocalHistoryEntry: LocalHistoryEntry?
    @Published private(set) var localHistoryDiffRows: [DiffRow] = []
    @Published private(set) var isLoadingLocalHistory = false
    @Published var projectLocalHistoryRequest: ProjectLocalHistoryRequest?
    @Published private(set) var projectLocalHistoryEntries: [LocalHistoryEntry] = []
    @Published var selectedProjectLocalHistoryEntry: LocalHistoryEntry?
    @Published private(set) var projectLocalHistoryDiffRows: [DiffRow] = []
    @Published private(set) var isLoadingProjectLocalHistory = false
    @Published private(set) var gitChanges: [GitChange] = []
    @Published private(set) var gitStashes: [GitStash] = []
    @Published private(set) var isPerformingStashOperation = false
    @Published private(set) var gitRepositoryRoot: URL?
    @Published private(set) var currentBranch = "No Git"
    @Published var selectedChange: GitChange?
    @Published private(set) var diffRows: [DiffRow] = []
    @Published private(set) var diffHunks: [DiffHunk] = []
    @Published var gitDiffWhitespaceMode = GitDiffWhitespaceMode.doNotIgnore
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var isRefreshingGit = false
    @Published var pendingDiscardChange: GitChange?
    @Published var pendingDiscardHunk: DiffHunkRequest?
    @Published var commitMessage = ""
    @Published var amendCommit = false
    @Published private(set) var isCommitting = false
    @Published var isGitLogVisible = false
    @Published var isTerminalVisible = false
    @Published var isReferencesVisible = false
    @Published var isProblemsVisible = false
    @Published var isMavenVisible = false
    @Published var isDebugVisible = false
    @Published var isImplementationChooserVisible = false
    @Published private(set) var javaNavigationLocations: [JavaNavigationLocation] = []
    @Published private(set) var javaNavigationResultKind = JavaNavigationResultKind.references
    @Published private(set) var isLoadingJavaNavigation = false
    @Published var editorCaret: EditorCaret?
    @Published var editorNavigationTarget: EditorNavigationTarget?
    @Published private(set) var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] = [:]
    @Published private(set) var javaInlayHints: [URL: [JavaInlayHint]] = [:]
    @Published private(set) var javaDiagnostics: [URL: [JavaDiagnostic]] = [:]
    @Published private(set) var gitBlameLines: [URL: [GitBlameLine]] = [:]
    @Published var blameVisibleURL: URL?
    @Published private(set) var gitReferences: [GitReference] = []
    @Published private(set) var gitCommits: [GitCommit] = []
    @Published var selectedGitReference: GitReference?
    @Published var selectedGitCommit: GitCommit?
    @Published private(set) var selectedGitCommitFiles: [GitCommitFile] = []
    @Published var selectedGitCommitFile: GitCommitFile?
    @Published var selectedGitCommitDiffContext: GitCommitDiffContext?
    @Published var gitLogSearchQuery = ""
    @Published private(set) var isLoadingGitHistory = false
    @Published private(set) var isLoadingMoreGitHistory = false
    @Published private(set) var canLoadMoreGitHistory = false
    @Published private(set) var branchComparison: GitBranchComparison?
    @Published var selectedBranchComparisonFile: GitBranchComparisonFile?
    @Published private(set) var branchComparisonRows: [DiffRow] = []
    @Published private(set) var isLoadingBranchComparison = false
    @Published private(set) var isPerformingBranchOperation = false
    private var directoryWatcher: DirectoryWatcher?
    private var doubleShiftDetector: DoubleShiftDetector?
    private var refreshTask: Task<Void, Never>?
    private var pendingExternalPaths: Set<String> = []
    private var externalRefreshGeneration = 0
    private var visibilityRulesRefreshTask: Task<Void, Never>?
    private var localHistorySeedTask: Task<Void, Never>?
    private var autoSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var inlayHintTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCloseQueue: [EditorDocument] = []
    private var pendingClosePreferredDocumentID: UUID?
    private var gitHistoryLimit = 300
    let projectRuntimeService: ProjectRuntimeService
    let settings = AppSettings()
    let terminalSession = TerminalSession()
    let javaLanguageService: JavaLanguageService
    let javaImplementationMarkerService: JavaImplementationMarkerService
    let mavenService: MavenService
    let javaRunService: JavaRunService
    let javaDebugService: JavaDebugService
    let searchIndex = WorkspaceSearchIndex()
    private var localHistoryService: LocalHistoryService?

    init() {
        let runtimeService = ProjectRuntimeService()
        projectRuntimeService = runtimeService
        mavenService = MavenService(runtimeService: runtimeService)
        javaRunService = JavaRunService(runtimeService: runtimeService)
        javaDebugService = JavaDebugService(runtimeService: runtimeService)
        let languageService = JavaLanguageService(runtimeService: runtimeService)
        javaLanguageService = languageService
        javaImplementationMarkerService = JavaImplementationMarkerService(languageService: languageService)
        recentProjects = RecentProjectsStore.load()
        settings.onFileVisibilityRulesChanged = { [weak self] in
            self?.applyVisibilityRules()
        }
        javaLanguageService.onDiagnostics = { [weak self] fileURL, diagnostics in
            self?.javaDiagnostics[fileURL.standardizedFileURL] = diagnostics
        }
        runtimeService.onRuntimeChanged = { [weak self] in
            self?.reloadJavaRuntimeServices()
        }
        doubleShiftDetector = DoubleShiftDetector { [weak self] in
            self?.toggleSearchEverywhere()
        }
        doubleShiftDetector?.start()
    }

    deinit {
        doubleShiftDetector?.stop()
    }

    private func reloadJavaRuntimeServices() {
        javaRunService.stop()
        javaDebugService.stop()
        mavenService.stop()
        javaLanguageService.stop()
        if let workspaceURL,
           projectFiles.contains(where: { $0.pathExtension.lowercased() == "java" }) {
            javaLanguageService.prepare(for: workspaceURL)
        }
    }

    var projectName: String {
        workspaceURL?.lastPathComponent ?? "Lithe"
    }

    var activeDocument: EditorDocument? {
        guard let activeDocumentID else { return nil }
        return openDocuments.first { $0.id == activeDocumentID }
    }

    var currentGitReference: GitReference? {
        gitReferences.first(where: \.isCurrent)
    }

    func chooseProject() {
        chooseProject(title: "Open a project", prompt: "Open")
    }

    func chooseProject(title: String, prompt: String) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func showCloneRepository() {
        isCloneRepositoryPresented = true
    }

    func cloneRepository(remote: String, destination: URL) async -> String? {
        let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemote.isEmpty else { return "Enter a repository URL" }
        guard !destination.path.isEmpty else { return "Choose a destination folder" }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return "The destination folder already exists"
        }

        isCloningRepository = true
        let result = await GitService.cloneRepository(from: normalizedRemote, to: destination)
        isCloningRepository = false
        guard result.succeeded else {
            return gitErrorMessage(from: result)
        }

        isCloneRepositoryPresented = false
        showNotification("Cloned \(destination.lastPathComponent)")
        openProject(destination)
        return nil
    }

    func openProject(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        if let previousWorkspaceURL = workspaceURL {
            persistWorkspaceSession(for: previousWorkspaceURL)
        }
        terminalSession.stop()
        projectRuntimeService.openProject(at: normalizedURL)
        mavenService.reset()
        javaRunService.reset()
        javaDebugService.reset()
        javaLanguageService.stop()
        javaLanguageService.configureProjectRoot(normalizedURL)
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        isRefreshingWorkspace = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        javaNavigationLocations = []
        editorCaret = nil
        editorNavigationTarget = nil
        javaCodeVisionHints = [:]
        javaDiagnostics = [:]
        gitBlameLines = [:]
        blameVisibleURL = nil
        gitChanges = []
        gitStashes = []
        gitRepositoryRoot = nil
        currentBranch = "No Git"
        selectedChange = nil
        diffRows = []
        diffHunks = []
        gitDiffWhitespaceMode = .doNotIgnore
        isLoadingDiff = false
        gitReferences = []
        gitCommits = []
        gitHistoryLimit = 300
        isLoadingMoreGitHistory = false
        canLoadMoreGitHistory = false
        selectedGitReference = nil
        selectedGitCommit = nil
        selectedGitCommitFiles = []
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        gitLogSearchQuery = ""
        localHistoryRequest = nil
        localHistoryEntries = []
        selectedLocalHistoryEntry = nil
        localHistoryDiffRows = []
        isLoadingLocalHistory = false
        projectLocalHistoryRequest = nil
        projectLocalHistoryEntries = []
        selectedProjectLocalHistoryEntry = nil
        projectLocalHistoryDiffRows = []
        isLoadingProjectLocalHistory = false
        workspaceURL = normalizedURL
        let visibilityRules = settings.fileVisibilityRules
        let historyService = LocalHistoryService(
            workspaceURL: normalizedURL,
            visibilityRules: visibilityRules
        )
        localHistoryService = historyService
        selectedSidebar = .project
        rootNode = nil
        projectFiles = []
        openDocuments = []
        activeDocumentID = nil
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = false
        isPerformingStashOperation = false
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        recentProjects = RecentProjectsStore.record(normalizedURL, in: recentProjects)
        isLoadingWorkspace = true

        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                WorkspaceScanner.snapshot(at: normalizedURL, rules: visibilityRules)
            }.value
            guard workspaceURL == normalizedURL else { return }
            rootNode = snapshot.root
            projectFiles = snapshot.files
            isLoadingWorkspace = false
            if snapshot.files.contains(where: { $0.pathExtension.lowercased() == "java" }) {
                javaLanguageService.prepare(for: normalizedURL)
            }
            restoreWorkspaceSession(for: normalizedURL, availableFiles: snapshot.files)
            await searchIndex.configure(at: normalizedURL)
            await searchIndex.update(files: snapshot.files)
            await refreshGit()
            await mavenService.loadProject(at: normalizedURL)
            await javaRunService.loadProject(
                at: normalizedURL,
                files: snapshot.files,
                mavenProject: mavenService.project
            )
            if settings.fileVisibilityRules == visibilityRules {
                startWatching(normalizedURL, visibilityRules: visibilityRules)
            }
            localHistorySeedTask?.cancel()
            localHistorySeedTask = Task(priority: .utility) {
                await historyService.seed(files: snapshot.files)
            }
        }
    }

    func closeProject() {
        if let workspaceURL {
            persistWorkspaceSession(for: workspaceURL)
        }
        workspaceURL = nil
        selectedSidebar = .project
        rootNode = nil
        projectFiles = []
        openDocuments = []
        activeDocumentID = nil
        searchResults = []
        searchQuery = ""
        isSearchEverywhereVisible = false
        searchEverywhereQuery = ""
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
        isProjectReplaceVisible = false
        projectReplaceQuery = ""
        projectReplaceText = ""
        projectReplacementFiles = []
        selectedProjectReplacementPaths = []
        isLoadingProjectReplacement = false
        isFindBarVisible = false
        findBarQuery = ""
        findMatchCount = 0
        currentFindMatchIndex = 0
        directoryWatcher?.stop()
        directoryWatcher = nil
        refreshTask?.cancel()
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        visibilityRulesRefreshTask?.cancel()
        isRefreshingWorkspace = false
        localHistorySeedTask?.cancel()
        localHistorySeedTask = nil
        localHistoryService = nil
        localHistoryRequest = nil
        localHistoryEntries = []
        selectedLocalHistoryEntry = nil
        localHistoryDiffRows = []
        projectLocalHistoryRequest = nil
        projectLocalHistoryEntries = []
        selectedProjectLocalHistoryEntry = nil
        projectLocalHistoryDiffRows = []
        isLoadingProjectLocalHistory = false
        gitChanges = []
        gitStashes = []
        gitRepositoryRoot = nil
        currentBranch = "No Git"
        selectedChange = nil
        diffRows = []
        diffHunks = []
        gitDiffWhitespaceMode = .doNotIgnore
        isLoadingDiff = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        terminalSession.stop()
        projectRuntimeService.closeProject()
        mavenService.reset()
        javaRunService.reset()
        javaDebugService.reset()
        Task { await searchIndex.reset() }
        javaLanguageService.stop()
        javaNavigationLocations = []
        editorCaret = nil
        editorNavigationTarget = nil
        javaCodeVisionHints = [:]
        javaDiagnostics = [:]
        gitBlameLines = [:]
        blameVisibleURL = nil
        gitReferences = []
        gitCommits = []
        gitHistoryLimit = 300
        isLoadingMoreGitHistory = false
        canLoadMoreGitHistory = false
        selectedGitReference = nil
        selectedGitCommit = nil
        selectedGitCommitFiles = []
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        gitLogSearchQuery = ""
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = false
        isPerformingStashOperation = false
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
        isPerformingBranchOperation = false
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects = RecentProjectsStore.remove(project, from: recentProjects)
    }

    func openFile(
        _ url: URL,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        selectedChange = nil
        closeBranchComparison()
        let normalizedURL = url.standardizedFileURL
        if let existing = openDocuments.first(where: { $0.url == normalizedURL }) {
            activeDocumentID = existing.id
            Task { await refreshCodeVision(for: existing.url) }
            refreshJavaInlayHints(for: existing)
            return
        }

        guard WorkspaceScanner.isReadableTextFile(normalizedURL),
              let text = try? String(contentsOf: normalizedURL, encoding: .utf8) else {
            showNotification("This file cannot be displayed as text")
            return
        }

        let document = EditorDocument(
            url: normalizedURL,
            text: text,
            modificationDate: EditorDocument.modificationDate(for: normalizedURL),
            isReadOnly: isReadOnly,
            displayPath: displayPath
        )
        openDocuments.append(document)
        activeDocumentID = document.id
        persistWorkspaceSession()
        guard !document.isReadOnly else { return }
        Task { await refreshCodeVision(for: normalizedURL) }
        refreshJavaInlayHints(for: document)
    }

    func refreshWorkspace() async {
        guard let workspaceURL, !isLoadingWorkspace, !isRefreshingWorkspace else { return }
        refreshTask?.cancel()
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        await rebuildWorkspace(
            at: workspaceURL,
            rules: settings.fileVisibilityRules,
            restartWatcher: false
        )
    }

    private func rebuildWorkspace(
        at workspaceURL: URL,
        rules: FileVisibilityRules,
        restartWatcher: Bool
    ) async {
        let isInitialLoad = rootNode == nil && projectFiles.isEmpty
        if isInitialLoad {
            isLoadingWorkspace = true
        } else {
            isRefreshingWorkspace = true
        }
        let snapshot = await Task.detached(priority: .userInitiated) {
            WorkspaceScanner.snapshot(at: workspaceURL, rules: rules)
        }.value
        guard self.workspaceURL == workspaceURL else {
            if isInitialLoad {
                isLoadingWorkspace = false
            } else {
                isRefreshingWorkspace = false
            }
            return
        }
        rootNode = snapshot.root
        projectFiles = snapshot.files
        if isInitialLoad {
            isLoadingWorkspace = false
        } else {
            isRefreshingWorkspace = false
        }
        if snapshot.files.contains(where: { $0.pathExtension.lowercased() == "java" }) {
            javaLanguageService.prepare(for: workspaceURL)
        }
        await searchIndex.configure(at: workspaceURL)
        await searchIndex.update(files: snapshot.files)
        await refreshGit()
        await mavenService.loadProject(at: workspaceURL)
        await javaRunService.loadProject(
            at: workspaceURL,
            files: snapshot.files,
            mavenProject: mavenService.project
        )
        if restartWatcher {
            startWatching(workspaceURL, visibilityRules: rules)
        }
    }

    func requestCreateFile(in directory: URL) {
        guard !isPerformingProjectItemOperation, isWorkspaceURL(directory) else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .createFile, targetURL: directory)
    }

    func requestCreateDirectory(in directory: URL) {
        guard !isPerformingProjectItemOperation, isWorkspaceURL(directory) else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .createDirectory, targetURL: directory)
    }

    func requestRenameProjectItem(at url: URL) {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(url),
              url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .rename, targetURL: url)
    }

    func cancelProjectItemEdit() {
        projectItemEditRequest = nil
    }

    func performProjectItemEdit(named rawName: String) async {
        guard let request = projectItemEditRequest else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProjectItemName(name) else {
            showNotification("Use a valid file or directory name")
            return
        }
        projectItemEditRequest = nil
        isPerformingProjectItemOperation = true

        let destination: URL
        switch request.kind {
        case .createFile, .createDirectory:
            destination = request.targetURL.appendingPathComponent(name)
        case .rename:
            destination = request.targetURL.deletingLastPathComponent().appendingPathComponent(name)
        }

        let relocatedHistoryFiles: [(source: URL, destination: URL)]
        if request.kind == .rename {
            let sourcePath = request.targetURL.standardizedFileURL.path
            let affectedFiles = projectFiles.filter { urlContains(request.targetURL, child: $0) }
            relocatedHistoryFiles = affectedFiles.map { source in
                let suffix = String(source.standardizedFileURL.path.dropFirst(sourcePath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return (source, suffix.isEmpty ? destination : destination.appendingPathComponent(suffix))
            }
            await recordHistory(containedIn: request.targetURL, reason: .beforeRename)
        } else {
            relocatedHistoryFiles = []
        }

        let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
            let manager = FileManager.default
            guard !manager.fileExists(atPath: destination.path) else {
                return "An item named '\(name)' already exists"
            }
            do {
                switch request.kind {
                case .createFile:
                    try Data().write(to: destination, options: .withoutOverwriting)
                case .createDirectory:
                    try manager.createDirectory(at: destination, withIntermediateDirectories: false)
                case .rename:
                    try manager.moveItem(at: request.targetURL, to: destination)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        isPerformingProjectItemOperation = false
        if let errorMessage {
            showNotification(errorMessage)
            return
        }

        if request.kind == .rename {
            if let localHistoryService {
                for relocation in relocatedHistoryFiles {
                    try? await localHistoryService.relocateHistory(
                        from: relocation.source,
                        to: relocation.destination
                    )
                }
            }
            relocateOpenDocuments(from: request.targetURL, to: destination)
            showNotification("Renamed to \(name)")
        } else if request.kind == .createFile {
            showNotification("Created \(name)")
        } else {
            showNotification("Created directory \(name)")
        }
        await refreshWorkspace()
        if request.kind == .createFile {
            openFile(destination)
        }
    }

    func duplicateProjectItem(at sourceURL: URL) async {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(sourceURL),
              sourceURL.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        isPerformingProjectItemOperation = true
        let destination = availableDuplicateURL(for: sourceURL)
        let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        isPerformingProjectItemOperation = false
        if let errorMessage {
            showNotification(errorMessage)
        } else {
            showNotification("Duplicated \(sourceURL.lastPathComponent)")
            await refreshWorkspace()
        }
    }

    func requestDeleteProjectItem(at url: URL, isDirectory: Bool) {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(url),
              url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        if openDocuments.contains(where: { document in
            document.isDirty && urlContains(url, child: document.url)
        }) {
            showNotification("Save or discard unsaved files before deleting this item")
            return
        }
        pendingProjectItemDeletion = ProjectItemDeletionRequest(url: url, isDirectory: isDirectory)
    }

    func cancelProjectItemDeletion() {
        pendingProjectItemDeletion = nil
    }

    func confirmProjectItemDeletion() async {
        guard let request = pendingProjectItemDeletion else { return }
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = true
        await recordHistory(containedIn: request.url, reason: .beforeDelete)
        let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: request.url,
                    resultingItemURL: &resultingURL
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        isPerformingProjectItemOperation = false
        if let errorMessage {
            showNotification(errorMessage)
            return
        }
        closeDocuments(containedIn: request.url)
        showNotification("Moved \(request.url.lastPathComponent) to Trash")
        await refreshWorkspace()
    }

    func revealProjectItemInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyProjectItemPath(_ url: URL, relative: Bool) {
        let relativeValue = relativePath(for: url)
        let value = relative ? (relativeValue.isEmpty ? "." : relativeValue) : url.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showNotification(relative ? "Copied relative path" : "Copied path")
    }

    func showLocalHistory(for fileURL: URL) {
        guard isWorkspaceURL(fileURL), WorkspaceScanner.isReadableTextFile(fileURL) else {
            showNotification("Local History is available for text files")
            return
        }
        localHistoryRequest = LocalHistoryRequest(fileURL: fileURL.standardizedFileURL)
        localHistoryEntries = []
        selectedLocalHistoryEntry = nil
        localHistoryDiffRows = []
        isLoadingLocalHistory = true
        Task { await reloadLocalHistory() }
    }

    func showProjectLocalHistory() {
        guard workspaceURL != nil else { return }
        projectLocalHistoryRequest = ProjectLocalHistoryRequest()
        projectLocalHistoryEntries = []
        selectedProjectLocalHistoryEntry = nil
        projectLocalHistoryDiffRows = []
        isLoadingProjectLocalHistory = true
        Task { await reloadProjectLocalHistory() }
    }

    func selectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        selectedLocalHistoryEntry = entry
        localHistoryDiffRows = []
        isLoadingLocalHistory = true
        Task { await loadLocalHistoryDiff(for: entry) }
    }

    func selectProjectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        selectedProjectLocalHistoryEntry = entry
        projectLocalHistoryDiffRows = []
        isLoadingProjectLocalHistory = true
        Task { await loadProjectLocalHistoryDiff(for: entry) }
    }

    func refreshLocalHistory() async {
        isLoadingLocalHistory = true
        await reloadLocalHistory()
        if let selectedLocalHistoryEntry {
            await loadLocalHistoryDiff(for: selectedLocalHistoryEntry)
        }
    }

    func refreshProjectLocalHistory() async {
        isLoadingProjectLocalHistory = true
        await reloadProjectLocalHistory()
        if let selectedProjectLocalHistoryEntry {
            await loadProjectLocalHistoryDiff(for: selectedProjectLocalHistoryEntry)
        }
    }

    func restoreSelectedLocalHistoryEntry() async {
        guard let request = localHistoryRequest,
              let entry = selectedLocalHistoryEntry,
              let localHistoryService else { return }
        do {
            let restoredText = try await localHistoryService.content(for: entry)
            if let document = openDocuments.first(where: { $0.url == request.fileURL }) {
                _ = try? await localHistoryService.record(
                    text: document.text,
                    for: request.fileURL,
                    reason: .restored
                )
            } else {
                _ = try? await localHistoryService.recordFile(at: request.fileURL, reason: .restored)
            }
            try restoredText.write(to: request.fileURL, atomically: true, encoding: .utf8)
            if let document = openDocuments.first(where: { $0.url == request.fileURL }) {
                try document.reloadFromDisk()
                activeDocumentID = document.id
            } else {
                openFile(request.fileURL)
            }
            showNotification("Restored \(request.fileURL.lastPathComponent)")
            await refreshWorkspace()
            await reloadLocalHistory(selectNewest: true)
        } catch {
            showNotification("Could not restore local history")
        }
    }

    func restoreSelectedProjectLocalHistoryEntry() async {
        guard let entry = selectedProjectLocalHistoryEntry,
              let workspaceURL,
              let localHistoryService else { return }

        let targetURL = workspaceURL
            .appendingPathComponent(entry.relativePath)
            .standardizedFileURL
        guard isWorkspaceURL(targetURL), WorkspaceScanner.isReadableTextFile(targetURL) else {
            showNotification("Could not restore this project history entry")
            return
        }

        do {
            let restoredText = try await localHistoryService.content(for: entry)
            if let document = openDocuments.first(where: { $0.url == targetURL }) {
                _ = try? await localHistoryService.record(
                    text: document.text,
                    for: targetURL,
                    reason: .restored
                )
            } else if FileManager.default.fileExists(atPath: targetURL.path) {
                _ = try? await localHistoryService.recordFile(at: targetURL, reason: .restored)
            }

            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try restoredText.write(to: targetURL, atomically: true, encoding: .utf8)

            if let document = openDocuments.first(where: { $0.url == targetURL }) {
                try document.reloadFromDisk()
                activeDocumentID = document.id
            }

            showNotification("Restored \(entry.relativePath)")
            await refreshWorkspace()
            await reloadProjectLocalHistory(selectNewest: true)
        } catch {
            showNotification("Could not restore project history")
        }
    }

    func requestCloseDocument(_ document: EditorDocument) {
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
        if document.isDirty {
            pendingCloseDocument = document
        } else {
            closeDocument(document)
        }
    }

    /// 关闭一组编辑器标签,先关闭未修改的标签,修改过的标签逐个经过现有保存确认。
    /// preferredDocumentID 用于“关闭其他标签”这类操作,保证右键目标标签仍保持激活。
    func requestCloseDocuments(
        _ documents: [EditorDocument],
        preferredDocumentID: UUID? = nil
    ) {
        let openIDs = Set(openDocuments.map(\.id))
        let targets = documents.filter { openIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        pendingCloseQueue = []
        pendingClosePreferredDocumentID = preferredDocumentID
        let dirtyDocuments = targets.filter(\.isDirty)
        targets.filter { !$0.isDirty }.forEach(closeDocument)

        if let firstDirty = dirtyDocuments.first {
            pendingCloseQueue = Array(dirtyDocuments.dropFirst())
            pendingCloseDocument = firstDirty
        } else {
            activatePreferredDocumentIfPossible()
        }
    }

    func closePendingDocument(discardingChanges: Bool) {
        guard let document = pendingCloseDocument else { return }
        if discardingChanges {
            recordDiscardedEditorText(document)
        } else {
            do {
                let previousText = document.savedText
                try document.save()
                recordSave(document, previousText: previousText)
            } catch {
                showNotification("Could not save \(document.url.lastPathComponent)")
                return
            }
        }
        pendingCloseDocument = nil
        closeDocument(document)
        if let nextDocument = pendingCloseQueue.first {
            pendingCloseQueue.removeFirst()
            pendingCloseDocument = nextDocument
        } else {
            activatePreferredDocumentIfPossible()
        }
    }

    func cancelPendingClose() {
        pendingCloseDocument = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
    }

    func saveActiveDocument() {
        guard let document = activeDocument else { return }
        guard !document.isReadOnly else {
            showNotification("This document is read-only")
            return
        }
        do {
            let previousText = document.savedText
            try document.save()
            recordSave(document, previousText: previousText)
            showNotification("Saved \(document.url.lastPathComponent)")
        } catch {
            showNotification("Could not save \(document.url.lastPathComponent)")
        }
    }

    func documentDidChange(_ document: EditorDocument) {
        javaLanguageService.update(document)
        inlayHintTasks[document.id]?.cancel()
        inlayHintTasks[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, let document else { return }
            self.refreshJavaInlayHints(for: document)
            self.inlayHintTasks[document.id] = nil
        }
        autoSaveTasks[document.id]?.cancel()
        guard settings.autoSave else { return }
        let delay = settings.autoSaveDelay
        autoSaveTasks[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let document, document.isDirty else { return }
            do {
                let previousText = document.savedText
                try document.save()
                self.recordSave(document, previousText: previousText)
            } catch {
                self.showNotification("Could not auto-save \(document.url.lastPathComponent)")
            }
            self.autoSaveTasks[document.id] = nil
        }
    }

    func searchProject(options: ProjectSearchOptions = .default) async {
        guard workspaceURL != nil else { return }
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let files = projectFiles
        let results = await searchIndex.searchProject(
            query: query,
            files: files,
            options: options
        )
        guard searchQuery == query else { return }
        searchResults = results
        isSearching = false
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
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
    }

    func searchEverywhere(options: ProjectSearchOptions = .default) async {
        guard let workspaceURL else {
            searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
            isSearchingEverywhere = false
            return
        }
        let query = searchEverywhereQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
            isSearchingEverywhere = false
            return
        }

        isSearchingEverywhere = true
        let files = projectFiles
        let indexedResults = await searchIndex.searchEverywhere(
            query: query,
            files: files,
            options: options
        )
        let semanticResults = await javaWorkspaceSearchResults(
            query: query,
            rootURL: workspaceURL,
            files: files,
            options: options
        )
        guard searchEverywhereQuery == query else { return }
        let actionMatches = LitheActionRegistry.actions(for: self).filter { $0.matches(query) }
        if let semanticResults {
            searchEverywhereResults = SearchEverywhereResults(
                fileMatches: indexedResults.fileMatches,
                classMatches: semanticResults.filter { $0.kind == .type },
                symbolMatches: semanticResults.filter { $0.kind == .symbol },
                contentMatches: indexedResults.contentMatches,
                actionMatches: actionMatches
            )
        } else {
            searchEverywhereResults = SearchEverywhereResults(
                fileMatches: indexedResults.fileMatches,
                classMatches: indexedResults.classMatches,
                symbolMatches: indexedResults.symbolMatches,
                contentMatches: indexedResults.contentMatches,
                actionMatches: actionMatches
            )
        }
        isSearchingEverywhere = false
    }

    private func javaWorkspaceSearchResults(
        query: String,
        rootURL: URL,
        files: [URL],
        options: ProjectSearchOptions
    ) async -> [FileSearchResult]? {
        guard files.contains(where: { $0.pathExtension.lowercased() == "java" }) else { return [] }
        return await withCheckedContinuation { continuation in
            javaLanguageService.workspaceSymbols(
                query: query,
                rootURL: rootURL,
                documents: openDocuments
            ) { result in
                switch result {
                case .failure:
                    continuation.resume(returning: nil)
                case .success(let symbols):
                    let results = symbols.compactMap { symbol -> FileSearchResult? in
                        guard symbol.url.pathExtension.lowercased() == "java",
                              self.urlContains(rootURL, child: symbol.url) else { return nil }
                        let kind: SearchResultKind = symbol.isType ? .type : .symbol
                        let location = symbol.containerName.map { $0 + " · " } ?? ""
                        return FileSearchResult(
                            url: symbol.url,
                            line: symbol.line + 1,
                            preview: location + symbol.name,
                            kind: kind,
                            symbolName: symbol.name
                        )
                    }
                    continuation.resume(
                        returning: results.filter {
                            options.matches($0.symbolName ?? $0.preview, query: query)
                        }
                    )
                }
            }
        }
    }

    func clearProjectReplacementPreview() {
        projectReplacementFiles = []
        selectedProjectReplacementPaths = []
    }

    func openProjectReplace() {
        guard workspaceURL != nil else { return }
        projectReplaceQuery = searchQuery
        projectReplaceText = ""
        projectReplacementFiles = []
        selectedProjectReplacementPaths = []
        isProjectReplaceVisible = true
    }

    func previewProjectReplacement() async {
        guard workspaceURL != nil else { return }
        let query = projectReplaceQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            projectReplacementFiles = []
            selectedProjectReplacementPaths = []
            return
        }

        isLoadingProjectReplacement = true
        let files = projectFiles
        let overrides = Dictionary(uniqueKeysWithValues: openDocuments.map { ($0.url.standardizedFileURL.path, $0.text) })
        let results = await searchIndex.previewReplacement(
            query: query,
            replacement: projectReplaceText,
            files: files,
            textOverrides: overrides
        )
        guard projectReplaceQuery == query else { return }
        projectReplacementFiles = results
        selectedProjectReplacementPaths = Set(results.map(\.relativePath))
        isLoadingProjectReplacement = false
    }

    func applyProjectReplacement() async {
        guard self.workspaceURL != nil,
              let localHistoryService,
              !projectReplaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let query = projectReplaceQuery
        let replacement = projectReplaceText
        let selectedPaths = selectedProjectReplacementPaths
        let targets = projectReplacementFiles.filter { selectedPaths.contains($0.relativePath) }
        guard !targets.isEmpty else { return }

        isLoadingProjectReplacement = true
        var changedFiles = 0
        var failedFiles: [String] = []
        for target in targets {
            let document = openDocuments.first { $0.url.standardizedFileURL == target.url.standardizedFileURL }
            let currentText: String?
            if let document {
                currentText = document.text
            } else {
                currentText = try? String(contentsOf: target.url, encoding: .utf8)
            }
            guard let currentText else {
                failedFiles.append(target.relativePath)
                continue
            }

            let replacedText = ProjectReplacementEngine.replace(
                in: currentText,
                query: query,
                replacement: replacement
            )
            guard replacedText != currentText else { continue }

            do {
                _ = try await localHistoryService.record(
                    text: currentText,
                    for: target.url,
                    reason: .beforeBatchReplace
                )
            } catch {
                failedFiles.append(target.relativePath)
                continue
            }

            do {
                if let document {
                    document.text = replacedText
                    try document.save()
                } else {
                    try replacedText.write(to: target.url, atomically: true, encoding: .utf8)
                }
                changedFiles += 1
            } catch {
                if let document {
                    document.text = currentText
                }
                failedFiles.append(target.relativePath)
            }
        }

        isLoadingProjectReplacement = false
        isProjectReplaceVisible = false
        projectReplacementFiles = []
        selectedProjectReplacementPaths = []
        await searchIndex.update(files: projectFiles)
        await refreshWorkspace()
        if !failedFiles.isEmpty {
            showNotification("Could not replace in \(failedFiles.count) file(s)")
        } else if changedFiles > 0 {
            showNotification("Replaced text in \(changedFiles) file(s)")
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
        closeBranchComparison()
        selectedGitCommitDiffContext = nil
        selectedChange = change
        activeDocumentID = nil
        diffRows = []
        diffHunks = []
        isLoadingDiff = true
        let whitespace = gitDiffWhitespaceMode
        Task {
            let document = await GitService.diffDocument(for: change, whitespace: whitespace)
            guard selectedChange?.id == change.id else { return }
            diffRows = document.rows
            diffHunks = document.hunks
            isLoadingDiff = false
        }
    }

    func reloadSelectedChangeDiff(whitespace: GitDiffWhitespaceMode) async {
        gitDiffWhitespaceMode = whitespace
        guard let selectedChange else { return }
        isLoadingDiff = true
        let document = await GitService.diffDocument(for: selectedChange, whitespace: whitespace)
        guard self.selectedChange?.id == selectedChange.id else { return }
        diffRows = document.rows
        diffHunks = document.hunks
        isLoadingDiff = false
    }

    func refreshGit() async {
        guard let workspaceURL, !isRefreshingGit else { return }
        isRefreshingGit = true
        defer { isRefreshingGit = false }

        if let snapshot = await GitService.snapshot(for: workspaceURL) {
            gitRepositoryRoot = snapshot.repositoryRoot
            currentBranch = snapshot.branch
            gitChanges = snapshot.changes
            gitStashes = await GitService.stashes(at: snapshot.repositoryRoot)
            if let selectedChange,
               let updated = snapshot.changes.first(where: { $0.path == selectedChange.path }) {
                self.selectedChange = updated
                let document = await GitService.diffDocument(
                    for: updated,
                    whitespace: gitDiffWhitespaceMode
                )
                diffRows = document.rows
                diffHunks = document.hunks
            } else if selectedChange != nil {
                self.selectedChange = nil
                diffRows = []
                diffHunks = []
                isLoadingDiff = false
            }
        } else {
            gitRepositoryRoot = nil
            currentBranch = "No Git"
            gitChanges = []
            gitStashes = []
            selectedChange = nil
            diffRows = []
            diffHunks = []
            isLoadingDiff = false
        }

        if isGitLogVisible {
            await refreshGitHistory()
        }
        if let activeDocument {
            await refreshCodeVision(for: activeDocument.url)
        }
    }

    func stageSelectedChange() async {
        guard let selectedChange else { return }
        let result = await GitService.stage(selectedChange)
        showNotification(result.succeeded ? "Staged \(selectedChange.path)" : result.output)
        await refreshGit()
    }

    func unstageSelectedChange() async {
        guard let selectedChange else { return }
        let result = await GitService.unstage(selectedChange)
        showNotification(result.succeeded ? "Unstaged \(selectedChange.path)" : result.output)
        await refreshGit()
    }

    func stageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        let result = await GitService.stage(hunk: hunk, of: change)
        showNotification(result.succeeded ? "Staged a change block in \(change.path)" : result.output)
        await refreshGit()
    }

    func unstageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        let result = await GitService.unstage(hunk: hunk, of: change)
        showNotification(result.succeeded ? "Unstaged a change block in \(change.path)" : result.output)
        await refreshGit()
    }

    func requestDiscardHunk(_ hunk: DiffHunk, in change: GitChange) {
        pendingDiscardHunk = DiffHunkRequest(change: change, hunk: hunk)
    }

    func confirmDiscardHunk() async {
        guard let request = pendingDiscardHunk else { return }
        pendingDiscardHunk = nil
        let result = await GitService.discard(hunk: request.hunk, of: request.change)
        showNotification(result.succeeded ? "Discarded a change block in \(request.change.path)" : result.output)
        await refreshGit()
    }

    func cancelDiscardHunk() {
        pendingDiscardHunk = nil
    }

    func requestDiscardSelectedChange() {
        pendingDiscardChange = selectedChange
    }

    func confirmDiscardChange() async {
        guard let change = pendingDiscardChange else { return }
        pendingDiscardChange = nil
        let result = await GitService.discard(change)
        showNotification(result.succeeded ? "Discarded \(change.path)" : result.output)
        await refreshGit()
    }

    func cancelDiscardChange() {
        pendingDiscardChange = nil
    }

    func commitStagedChanges() async {
        guard let gitRepositoryRoot else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            showNotification("Enter a commit message")
            return
        }
        isCommitting = true
        let result = await GitService.commit(at: gitRepositoryRoot, message: message, amend: amendCommit)
        isCommitting = false
        if result.succeeded {
            commitMessage = ""
            amendCommit = false
            showNotification("Changes committed")
        } else {
            showNotification(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        await refreshGit()
    }

    func commitAndPushStagedChanges() async {
        guard let gitRepositoryRoot else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            showNotification("Enter a commit message")
            return
        }
        guard !gitChanges.filter(\.isStaged).isEmpty else {
            showNotification("Stage at least one change before committing")
            return
        }

        isCommitting = true
        let commitResult = await GitService.commit(
            at: gitRepositoryRoot,
            message: message,
            amend: amendCommit
        )
        guard commitResult.succeeded else {
            isCommitting = false
            showNotification(gitErrorMessage(from: commitResult))
            await refreshGit()
            return
        }

        commitMessage = ""
        amendCommit = false
        guard let currentReference = currentGitReference else {
            isCommitting = false
            showNotification("Committed changes, but detached HEAD cannot be pushed")
            await refreshGit()
            return
        }

        let pushResult = await GitService.push(currentReference, at: gitRepositoryRoot)
        isCommitting = false
        if pushResult.succeeded {
            showNotification("Committed and pushed \(currentReference.shortName)")
        } else {
            showNotification("Committed changes, but push failed: \(gitErrorMessage(from: pushResult))")
        }
        await refreshGit()
    }

    func toggleStaging(_ change: GitChange) async {
        selectedChange = change
        let result = change.isStaged ? await GitService.unstage(change) : await GitService.stage(change)
        let verb = change.isStaged ? "Unstaged" : "Staged"
        showNotification(result.succeeded ? "\(verb) \(change.path)" : result.output)
        await refreshGit()
    }

    func stageAllChanges() async {
        guard let gitRepositoryRoot else { return }
        let result = await GitService.stageAll(at: gitRepositoryRoot)
        showNotification(result.succeeded ? "Staged all changes" : result.output)
        await refreshGit()
    }

    func stashWorkingTree(message: String, includeUntracked: Bool) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await GitService.stash(
            message: message,
            includeUntracked: includeUntracked,
            at: gitRepositoryRoot
        )
        isPerformingStashOperation = false
        if result.succeeded {
            showNotification("Working tree stashed")
            await refreshGit()
        } else {
            showNotification(gitErrorMessage(from: result))
        }
    }

    func applyStash(_ stash: GitStash, pop: Bool = false) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = pop
            ? await GitService.popStash(stash, at: gitRepositoryRoot)
            : await GitService.applyStash(stash, at: gitRepositoryRoot)
        isPerformingStashOperation = false
        if result.succeeded {
            showNotification(pop ? "Popped \(stash.reference)" : "Applied \(stash.reference)")
            await refreshGit()
        } else {
            showNotification(gitErrorMessage(from: result))
        }
    }

    func dropStash(_ stash: GitStash) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await GitService.dropStash(stash, at: gitRepositoryRoot)
        isPerformingStashOperation = false
        showNotification(result.succeeded ? "Dropped \(stash.reference)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func toggleGitLog() async {
        isGitLogVisible.toggle()
        if isGitLogVisible {
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
        isGitLogVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        if !terminalSession.isRunning, let workspaceURL {
            terminalSession.start(in: workspaceURL, shellPath: settings.terminalShellPath)
        }
    }

    func toggleMaven() {
        isMavenVisible.toggle()
        guard isMavenVisible else { return }
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        guard let workspaceURL else { return }
        Task { [weak self] in
            guard let self else { return }
            if self.mavenService.project == nil {
                await self.mavenService.loadProject(at: workspaceURL)
            }
            guard self.workspaceURL == workspaceURL else { return }
            // Maven can finish loading after the initial workspace snapshot.
            // Refresh run configurations here so a Maven/Spring Boot project
            // does not remain stuck on the Current File configuration.
            await self.javaRunService.loadProject(
                at: workspaceURL,
                files: self.projectFiles,
                mavenProject: self.mavenService.project
            )
        }
    }

    func runMaven(
        phase: MavenLifecyclePhase,
        module: MavenModule?,
        profiles: Set<String>
    ) {
        isMavenVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        mavenService.run(phase: phase, module: module, profiles: profiles)
    }

    func stopMaven() {
        mavenService.stop()
    }

    func openMavenIssue(_ issue: MavenBuildIssue) {
        guard let fileURL = issue.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        openFile(fileURL)
        editorNavigationTarget = EditorNavigationTarget(
            url: fileURL.standardizedFileURL,
            line: max(0, (issue.line ?? 1) - 1),
            utf16Column: max(0, (issue.column ?? 1) - 1)
        )
    }

    /// 打开源码文件并定位到指定行/列(供构建输出、运行堆栈等可点击文本跳转)。
    func openSourceLocation(url: URL, line: Int, column: Int?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        openFile(url)
        editorNavigationTarget = EditorNavigationTarget(
            url: url.standardizedFileURL,
            line: max(0, line - 1),
            utf16Column: max(0, (column ?? 1) - 1)
        )
    }

    func toggleProblems() {
        isProblemsVisible.toggle()
        guard isProblemsVisible else { return }
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
    }

    func openJavaDiagnostic(_ diagnostic: JavaDiagnostic) {
        guard FileManager.default.fileExists(atPath: diagnostic.fileURL.path) else { return }
        openFile(diagnostic.fileURL)
        editorNavigationTarget = EditorNavigationTarget(
            url: diagnostic.fileURL.standardizedFileURL,
            line: diagnostic.line,
            utf16Column: diagnostic.utf16Column
        )
    }

    func selectRunConfiguration(_ configuration: JavaRunConfiguration) {
        javaRunService.select(configuration)
    }

    func runSelectedConfiguration() {
        guard let configuration = javaRunService.selectedConfiguration else { return }
        if configuration.kind == .currentFile,
           let document = activeDocument,
           document.isDirty {
            do {
                let previousText = document.savedText
                try document.save()
                recordSave(document, previousText: previousText)
            } catch {
                showNotification("Could not save \(document.url.lastPathComponent)")
                return
            }
        }
        isRunVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isMavenVisible = false
        isDebugVisible = false
        javaRunService.runSelected(currentFileURL: activeDocument?.url)
    }

    func restartSelectedRun() {
        isRunVisible = true
        javaRunService.restart()
    }

    func stopSelectedRun() {
        javaRunService.stop()
    }

    func toggleDebug() {
        isDebugVisible.toggle()
        guard isDebugVisible else { return }
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func startDebugging() {
        if javaDebugService.targetKind != .remote, !saveActiveDocumentBeforeDebug() {
            return
        }
        isDebugVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        switch javaDebugService.targetKind {
        case .currentFile:
            guard let document = activeDocument,
                  document.url.pathExtension.lowercased() == "java" else {
                showNotification("Open a Java file before starting Debug")
                return
            }
            javaDebugService.start(
                fileURL: document.url,
                sourceText: document.text,
                projectURL: workspaceURL,
                options: javaRunService.options(for: .currentFile)
            )
        case .runConfiguration:
            guard let configuration = javaRunService.selectedConfiguration,
                  configuration.kind == .springBoot || configuration.kind == .mavenModule else {
                showNotification("Select a Spring Boot or Maven Module configuration before starting Debug")
                return
            }
            guard let workspaceURL, let mavenProject = mavenService.project else {
                showNotification("No Maven project is available for Debug")
                return
            }
            javaDebugService.startMaven(
                configuration: configuration,
                project: mavenProject,
                projectURL: workspaceURL,
                options: javaRunService.options(for: configuration)
            )
        case .remote:
            javaDebugService.attachRemote()
        }
    }

    func stopDebugging() {
        javaDebugService.stop()
    }

    func toggleDebugBreakpointAtCaret() {
        guard let caret = editorCaret,
              let document = openDocuments.first(where: { $0.url == caret.url }),
              document.url.pathExtension.lowercased() == "java" else {
            showNotification("Place the caret in a Java file to set a breakpoint")
            return
        }
        toggleDebugBreakpoint(fileURL: document.url, line: caret.line + 1)
    }

    func toggleDebugBreakpoint(fileURL: URL, line: Int) {
        guard let document = openDocuments.first(where: {
            $0.url.standardizedFileURL == fileURL.standardizedFileURL
        }),
        document.url.pathExtension.lowercased() == "java",
        line > 0 else { return }
        let className = JavaDebugService.className(for: document.url, sourceText: document.text)
        javaDebugService.toggleBreakpoint(
            fileURL: document.url,
            line: line,
            className: className
        )
    }

    private func saveActiveDocumentBeforeDebug() -> Bool {
        guard let document = activeDocument, document.isDirty else { return true }
        do {
            let previousText = document.savedText
            try document.save()
            recordSave(document, previousText: previousText)
            return true
        } catch {
            showNotification("Could not save \(document.url.lastPathComponent)")
            return false
        }
    }

    func goToDefinition() {
        performJavaNavigation(method: "textDocument/definition", kind: .definitions)
    }

    func goToUsages() {
        performJavaNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleReference: true
        )
    }

    func goToImplementation() {
        guard let document = activeDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL,
              document.url.pathExtension.lowercased() == "java" else {
            showNotification("Place the caret on a Java symbol first")
            return
        }
        performJavaNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    func navigateToSymbol(line: Int, utf16Column: Int, in fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.pathExtension.lowercased() == "java" else { return }
        editorCaret = EditorCaret(
            url: normalizedURL,
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        performJavaNavigation(
            method: "textDocument/definition",
            kind: .definitions,
            fallbackToImplementationsIfSelf: true
        )
    }

    func findJavaReferences() {
        performJavaNavigation(method: "textDocument/references", kind: .references)
    }

    func findJavaImplementations(line: Int, utf16Column: Int, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: line,
            utf16Column: utf16Column
        )
        performJavaNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    func navigate(to location: JavaNavigationLocation) {
        isImplementationChooserVisible = false
        openFile(
            location.url,
            isReadOnly: location.isReadOnly,
            displayPath: location.displayPath
        )
        editorNavigationTarget = EditorNavigationTarget(
            url: location.url.standardizedFileURL,
            line: location.line,
            utf16Column: location.utf16Column
        )
    }

    func closeJavaNavigationResults() {
        isReferencesVisible = false
        isImplementationChooserVisible = false
    }

    private func performJavaNavigation(
        method: String,
        kind: JavaNavigationResultKind,
        fallbackToImplementationsIfSelf: Bool = false,
        navigateToSingleReference: Bool = false
    ) {
        guard !isLoadingJavaNavigation,
              let document = activeDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL else {
            showNotification("Place the caret on a Java symbol first")
            return
        }
        guard document.url.pathExtension.lowercased() == "java" else {
            showNotification("Java navigation is available for .java files")
            return
        }

        isLoadingJavaNavigation = true
        showNotification("Starting Java navigation...")
        javaLanguageService.locations(
            method: method,
            document: document,
            line: caret.line,
            utf16Column: caret.utf16Column
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingJavaNavigation = false
            switch result {
            case .failure(let error):
                self.showNotification(error.localizedDescription)
            case .success(let locations):
                if fallbackToImplementationsIfSelf,
                   kind == .definitions,
                   locations.count == 1,
                   locations[0].url.standardizedFileURL == document.url.standardizedFileURL {
                    self.isLoadingJavaNavigation = true
                    self.javaLanguageService.locations(
                        method: "textDocument/implementation",
                        document: document,
                        line: caret.line,
                        utf16Column: caret.utf16Column
                    ) { [weak self] implementationResult in
                        guard let self else { return }
                        self.isLoadingJavaNavigation = false
                        if case .success(let implementations) = implementationResult,
                           !implementations.isEmpty {
                            self.presentJavaNavigationResults(implementations, kind: .implementations)
                        } else {
                            self.presentJavaNavigationResults(locations, kind: .definitions)
                        }
                    }
                    return
                }
                self.presentJavaNavigationResults(
                    locations,
                    kind: kind,
                    navigateToSingleReference: navigateToSingleReference
                )
            }
        }
    }

    private func presentJavaNavigationResults(
        _ locations: [JavaNavigationLocation],
        kind: JavaNavigationResultKind,
        navigateToSingleReference: Bool = false
    ) {
        guard !locations.isEmpty else {
            let message: String
            switch kind {
            case .definitions:
                message = "Definition not found"
            case .references:
                message = "No usages found"
            case .implementations:
                message = "No implementations found"
            }
            showNotification(message)
            return
        }

        if (kind != .references || navigateToSingleReference),
           locations.count == 1,
           let location = locations.first {
            navigate(to: location)
            let message: String
            switch kind {
            case .definitions:
                message = "Opened definition"
            case .references:
                message = "Opened call site"
            case .implementations:
                message = "Opened implementation"
            }
            showNotification(message)
        } else {
            javaNavigationResultKind = kind
            javaNavigationLocations = locations
            isGitLogVisible = false
            isTerminalVisible = false
            isProblemsVisible = false
            isMavenVisible = false
            isRunVisible = false
            isReferencesVisible = kind != .implementations
            isImplementationChooserVisible = kind == .implementations
        }
    }

    func closeGitLog() {
        isGitLogVisible = false
    }

    func selectGitReference(_ reference: GitReference?) async {
        selectedGitReference = reference
        gitHistoryLimit = 300
        canLoadMoreGitHistory = false
        await refreshGitHistory()
    }

    func refreshGitHistory() async {
        guard let gitRepositoryRoot, !isLoadingGitHistory else { return }
        isLoadingGitHistory = true
        let previousCommitHash = selectedGitCommit?.hash
        let snapshot = await GitService.history(
            at: gitRepositoryRoot,
            reference: selectedGitReference,
            limit: gitHistoryLimit
        )
        gitReferences = snapshot.references
        gitCommits = snapshot.commits
        canLoadMoreGitHistory = snapshot.hasMore

        let nextCommit = snapshot.commits.first(where: { $0.hash == previousCommitHash }) ?? snapshot.commits.first
        isLoadingGitHistory = false
        if let nextCommit {
            if previousCommitHash == nextCommit.hash {
                // A normal refresh does not change an immutable commit's files.
                // Keep the already loaded detail pane in place instead of
                // briefly clearing it and fetching the same commit again.
                selectedGitCommit = nextCommit
            } else {
                await selectGitCommit(nextCommit)
            }
        } else {
            selectedGitCommit = nil
            selectedGitCommitFiles = []
            selectedGitCommitFile = nil
            selectedGitCommitDiffContext = nil
        }
    }

    func loadMoreGitHistory() async {
        guard canLoadMoreGitHistory, !isLoadingGitHistory else { return }
        isLoadingMoreGitHistory = true
        defer { isLoadingMoreGitHistory = false }
        gitHistoryLimit += 300
        await refreshGitHistory()
    }

    func selectGitCommit(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommit = commit
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        let files = await GitService.files(in: commit, at: gitRepositoryRoot)
        guard selectedGitCommit?.hash == commit.hash else { return }
        selectedGitCommitFiles = files
        selectedGitCommitFile = files.first
    }

    func showGitCommitDiff(for file: GitCommitFile) {
        guard let gitRepositoryRoot, let commit = selectedGitCommit else { return }
        let context = GitCommitDiffContext(
            repositoryRoot: gitRepositoryRoot,
            commit: commit,
            file: file
        )

        closeBranchComparison()
        selectedChange = nil
        selectedGitCommitFile = file
        selectedGitCommitDiffContext = context
        activeDocumentID = nil
        diffRows = []
        diffHunks = []
        isLoadingDiff = true

        Task { [weak self] in
            let document = await GitService.diffDocument(
                for: commit,
                file: file,
                at: gitRepositoryRoot
            )
            guard let self,
                  self.selectedGitCommitDiffContext?.id == context.id else { return }
            self.diffRows = document.rows
            self.diffHunks = document.hunks
            self.isLoadingDiff = false
        }
    }

    func closeGitCommitDiff() {
        selectedGitCommitDiffContext = nil
        selectedGitCommitFile = nil
        diffRows = []
        diffHunks = []
        isLoadingDiff = false
    }

    func refreshCodeVision(for fileURL: URL) async {
        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.pathExtension.lowercased() == "java",
              let document = openDocuments.first(where: { $0.url.standardizedFileURL == normalizedURL }),
              !document.isReadOnly,
              let gitRepositoryRoot else { return }
        let blame = await GitService.blame(fileURL: normalizedURL, at: gitRepositoryRoot)
        let baseHints = await JavaCodeVisionService.hints(
            for: normalizedURL,
            projectFiles: projectFiles,
            blameLines: blame
        )
        guard openDocuments.contains(where: { $0.url == normalizedURL }) else { return }
        let implementationCounts: [Int: Int]
        let candidates = JavaEditorStructureService.implementationMarkers(in: document.text)
        let markers = await javaImplementationMarkerService.markers(
            for: document,
            candidates: candidates
        )
        implementationCounts = Dictionary(
            uniqueKeysWithValues: markers.map { ($0.line, $0.implementationCount) }
        )
        let hints = baseHints.map { hint in
            JavaCodeVisionHint(
                line: hint.line,
                utf16Column: hint.utf16Column,
                symbol: hint.symbol,
                usageCount: hint.usageCount,
                implementationCount: implementationCounts[hint.line] ?? 0,
                authorName: hint.authorName
            )
        }
        gitBlameLines[normalizedURL] = blame
        javaCodeVisionHints[normalizedURL] = hints
    }

    func refreshJavaInlayHints(for document: EditorDocument) {
        guard !document.isReadOnly else { return }
        requestJavaInlayHints(for: document, attempt: 0)
    }

    private func requestJavaInlayHints(for document: EditorDocument, attempt: Int) {
        let url = document.url.standardizedFileURL
        guard url.pathExtension.lowercased() == "java" else { return }
        javaLanguageService.inlayHints(document: document) { [weak self, weak document] result in
            guard let self, let document,
                  self.openDocuments.contains(where: { $0.id == document.id }) else { return }
            if case .success(let hints) = result {
                self.javaInlayHints[url] = hints
                if hints.isEmpty, attempt < 3 {
                    Task { [weak self, weak document] in
                        try? await Task.sleep(for: .milliseconds(900 * (attempt + 1)))
                        guard let self, let document,
                              self.openDocuments.contains(where: { $0.id == document.id }) else { return }
                        self.requestJavaInlayHints(for: document, attempt: attempt + 1)
                    }
                } else if hints.isEmpty {
                    let files = self.projectFiles.filter { $0.pathExtension.lowercased() == "java" }
                    let currentText = document.text
                    let documentID = document.id
                    Task { [weak self] in
                        let fallback = await Task.detached {
                            let sources = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                            return JavaEditorStructureService.fallbackParameterHints(
                                in: currentText,
                                declarationSources: sources
                            )
                        }.value
                        guard let self,
                              self.openDocuments.contains(where: { $0.id == documentID }) else { return }
                        self.javaInlayHints[url] = fallback
                    }
                }
            }
        }
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
        findJavaReferences()
    }

    func showGitCommit(_ hash: String) async {
        guard let gitRepositoryRoot, !hash.allSatisfy({ $0 == "0" }) else { return }
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        isGitLogVisible = true
        if gitCommits.isEmpty {
            await refreshGitHistory()
        }
        let commit: GitCommit?
        if let existing = gitCommits.first(where: { $0.hash == hash }) {
            commit = existing
        } else {
            commit = await GitService.commit(withHash: hash, at: gitRepositoryRoot)
        }
        if let commit {
            if !gitCommits.contains(where: { $0.hash == commit.hash }) {
                gitCommits.insert(commit, at: 0)
            }
            await selectGitCommit(commit)
        }
    }

    func showComparisonWithWorkingTree(for reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommitDiffContext = nil
        selectedChange = nil
        activeDocumentID = nil
        isLoadingBranchComparison = true
        branchComparisonRows = []
        let comparison = await GitService.comparisonWithWorkingTree(
            for: reference,
            at: gitRepositoryRoot
        )
        branchComparison = comparison
        selectedBranchComparisonFile = comparison.files.first
        if let firstFile = comparison.files.first {
            branchComparisonRows = await GitService.diff(
                for: firstFile,
                against: reference,
                at: gitRepositoryRoot
            )
        }
        isLoadingBranchComparison = false
    }

    func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
        guard let gitRepositoryRoot, let comparison = branchComparison else { return }
        selectedBranchComparisonFile = file
        branchComparisonRows = []
        isLoadingBranchComparison = true
        let rows = await GitService.diff(
            for: file,
            against: comparison.reference,
            at: gitRepositoryRoot
        )
        guard selectedBranchComparisonFile?.id == file.id else { return }
        branchComparisonRows = rows
        isLoadingBranchComparison = false
    }

    func closeBranchComparison() {
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
    }

    func createBranch(
        named rawName: String,
        from reference: GitReference,
        checkout: Bool
    ) async {
        guard let gitRepositoryRoot else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showNotification("Enter a branch name")
            return
        }
        isPerformingBranchOperation = true
        let result = await GitService.createBranch(
            named: name,
            from: reference,
            checkout: checkout,
            at: gitRepositoryRoot
        )
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            showNotification(checkout ? "Created and checked out \(name)" : "Created branch \(name)")
            await refreshGit()
        } else {
            showNotification(gitErrorMessage(from: result))
        }
    }

    func renameBranch(_ reference: GitReference, to rawName: String) async {
        guard let gitRepositoryRoot else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showNotification("Enter a branch name")
            return
        }
        isPerformingBranchOperation = true
        let result = await GitService.renameBranch(reference, to: name, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            closeBranchComparison()
            showNotification("Renamed branch to \(name)")
            await refreshGit()
        } else {
            showNotification(gitErrorMessage(from: result))
        }
    }

    func deleteBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.deleteBranch(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Deleted \(reference.shortName)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func mergeBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.mergeBranch(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Merged \(reference.shortName)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func rebaseCurrentBranch(onto reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.rebaseCurrentBranch(onto: reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Rebased onto \(reference.shortName)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func updateCurrentBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot, reference.isCurrent else {
            showNotification("Only the current branch can be updated")
            return
        }
        isPerformingBranchOperation = true
        let result = await GitService.updateCurrentBranch(at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Updated \(reference.shortName)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func fetchGit() async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.fetch(at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Fetched Git remotes" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func checkoutReference(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        if reference.isCurrent {
            showNotification("Already on \(reference.shortName)")
            return
        }
        isPerformingBranchOperation = true
        let result = await GitService.checkout(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            closeBranchComparison()
            showNotification("Checked out \(reference.shortName)")
            await refreshGit()
        } else {
            showNotification(gitErrorMessage(from: result))
        }
    }

    func checkoutRevision(_ rawRevision: String) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.checkoutRevision(rawRevision, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            closeBranchComparison()
            showNotification("Checked out \(rawRevision) in detached HEAD")
            await refreshGit()
        } else {
            showNotification(gitErrorMessage(from: result))
        }
    }

    func cherryPick(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.cherryPick(commit.hash, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Cherry-picked \(commit.shortHash)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func revert(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.revert(commit.hash, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Reverted \(commit.shortHash)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func resetCurrentBranch(to commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.resetCurrentBranch(
            to: commit.hash,
            at: gitRepositoryRoot,
            mode: "--mixed"
        )
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Reset current branch to \(commit.shortHash)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func pushBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await GitService.push(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        showNotification(result.succeeded ? "Pushed \(reference.shortName)" : gitErrorMessage(from: result))
        await refreshGit()
    }

    func loadExternalVersion(of document: EditorDocument) {
        do {
            if document.isDirty, let localHistoryService {
                let text = document.text
                let url = document.url
                Task {
                    _ = try? await localHistoryService.record(
                        text: text,
                        for: url,
                        reason: .unsavedDiscard
                    )
                }
            }
            try document.reloadFromDisk()
            showNotification("Loaded file-system version")
        } catch {
            showNotification("Could not reload \(document.url.lastPathComponent)")
        }
    }

    func keepEditorVersion(of document: EditorDocument) {
        document.keepEditorVersion()
        showNotification("Kept editor version")
    }

    func relativePath(for url: URL) -> String {
        guard let workspaceURL else { return url.lastPathComponent }
        return WorkspaceScanner.relativePath(for: url, root: workspaceURL)
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

    private func gitErrorMessage(from result: GitService.CommandResult) -> String {
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Git operation failed" : message
    }

    private func closeDocument(_ document: EditorDocument) {
        guard let index = openDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        javaLanguageService.close(document)
        javaImplementationMarkerService.invalidate(document)
        javaDiagnostics[document.url.standardizedFileURL] = nil
        let wasActive = activeDocumentID == document.id
        openDocuments.remove(at: index)
        if wasActive {
            if openDocuments.indices.contains(index) {
                activeDocumentID = openDocuments[index].id
            } else {
                activeDocumentID = openDocuments.last?.id
            }
        }
        persistWorkspaceSession()
    }

    private func persistWorkspaceSession(for explicitWorkspaceURL: URL? = nil) {
        guard let targetURL = explicitWorkspaceURL ?? workspaceURL else { return }
        WorkspaceSessionStore.save(
            WorkspaceSession(
                openPaths: openDocuments.map { $0.url.standardizedFileURL.path },
                activePath: activeDocument?.url.standardizedFileURL.path,
                selectedSidebar: selectedSidebar.rawValue
            ),
            for: targetURL
        )
    }

    private func restoreWorkspaceSession(for workspaceURL: URL, availableFiles: [URL]) {
        guard let session = WorkspaceSessionStore.load(for: workspaceURL) else { return }
        let availablePaths = Set(availableFiles.map { $0.standardizedFileURL.path })
        selectedSidebar = SidebarDestination(rawValue: session.selectedSidebar) ?? .project

        for path in session.openPaths where availablePaths.contains(path) {
            openFile(URL(fileURLWithPath: path))
        }
        if let activePath = session.activePath,
           let document = openDocuments.first(where: { $0.url.standardizedFileURL.path == activePath }) {
            activeDocumentID = document.id
        }
    }

    private func activatePreferredDocumentIfPossible() {
        defer { pendingClosePreferredDocumentID = nil }
        guard let preferredDocumentID = pendingClosePreferredDocumentID,
              openDocuments.contains(where: { $0.id == preferredDocumentID }) else { return }
        activeDocumentID = preferredDocumentID
    }

    private func closeDocuments(containedIn url: URL) {
        let documents = openDocuments.filter { urlContains(url, child: $0.url) }
        for document in documents {
            closeDocument(document)
        }
    }

    private func relocateOpenDocuments(from sourceURL: URL, to destinationURL: URL) {
        let sourcePath = sourceURL.standardizedFileURL.path
        for document in openDocuments where urlContains(sourceURL, child: document.url) {
            let documentPath = document.url.standardizedFileURL.path
            let suffix = String(documentPath.dropFirst(sourcePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relocatedURL = suffix.isEmpty
                ? destinationURL
                : destinationURL.appendingPathComponent(suffix)
            document.relocate(to: relocatedURL)
        }
    }

    private func availableDuplicateURL(for sourceURL: URL) -> URL {
        let parent = sourceURL.deletingLastPathComponent()
        let fileExtension = sourceURL.pathExtension
        let baseName = fileExtension.isEmpty
            ? sourceURL.lastPathComponent
            : sourceURL.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = fileExtension.isEmpty
                ? "\(baseName)\(suffix)"
                : "\(baseName)\(suffix).\(fileExtension)"
            let candidate = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func isValidProjectItemName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }

    private func isWorkspaceURL(_ url: URL) -> Bool {
        guard let workspaceURL else { return false }
        return urlContains(workspaceURL, child: url)
    }

    private func urlContains(_ parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private func startWatching(
        _ url: URL,
        visibilityRules: FileVisibilityRules
    ) {
        directoryWatcher?.stop()
        directoryWatcher = DirectoryWatcher(
            root: url,
            visibilityRules: visibilityRules
        ) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.scheduleExternalRefresh(paths: paths)
            }
        }
        directoryWatcher?.start()
    }

    private func scheduleExternalRefresh(paths: [String]) {
        guard !paths.isEmpty else { return }
        pendingExternalPaths.formUnion(paths)
        externalRefreshGeneration += 1
        let generation = externalRefreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  let self,
                  self.externalRefreshGeneration == generation,
                  let workspaceURL = self.workspaceURL else { return }
            let changedPaths = Array(self.pendingExternalPaths)
            self.pendingExternalPaths.removeAll()
            await self.applyExternalRefresh(changedPaths, at: workspaceURL)
        }
    }

    private func applyExternalRefresh(_ paths: [String], at workspaceURL: URL) async {
        guard self.workspaceURL == workspaceURL else { return }
        if isLoadingWorkspace || isRefreshingWorkspace {
            scheduleExternalRefresh(paths: paths)
            return
        }

        let changedURLs = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter(isWorkspaceURL)
        let changedPathSet = Set(changedURLs.map(\.path))
        var conflictDetected = false
        for document in openDocuments where changedPathSet.contains(document.url.standardizedFileURL.path) {
            if document.processPossibleExternalChange(), document.hasExternalConflict {
                conflictDetected = true
            }
        }

        if let localHistoryService {
            let changedFiles = changedURLs.filter { url in
                FileManager.default.fileExists(atPath: url.path)
            }
            Task(priority: .utility) {
                for fileURL in changedFiles {
                    _ = try? await localHistoryService.recordFile(at: fileURL, reason: .externalChange)
                }
            }
        }
        if conflictDetected {
            showNotification("External edits conflict with unsaved changes")
        }

        let requiresWorkspaceSnapshot = changedURLs.contains { url in
            let wasKnownFile = projectFiles.contains { $0.standardizedFileURL.path == url.path }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return wasKnownFile
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory || !wasKnownFile
        }
        if requiresWorkspaceSnapshot {
            await rebuildWorkspace(
                at: workspaceURL,
                rules: settings.fileVisibilityRules,
                restartWatcher: false
            )
            return
        }

        // Content-only edits do not change the tree. Updating the existing file list
        // refreshes the index metadata while keeping selection, expansion, and scroll
        // position intact.
        await searchIndex.update(files: projectFiles)

        let requiresProjectServiceReload = changedURLs.contains { url in
            let name = url.lastPathComponent.lowercased()
            return name == "pom.xml" || name == "build.gradle" || name == "build.gradle.kts"
                || url.pathExtension.lowercased() == "java"
        }
        if requiresProjectServiceReload {
            await mavenService.loadProject(at: workspaceURL)
            await javaRunService.loadProject(
                at: workspaceURL,
                files: projectFiles,
                mavenProject: mavenService.project
            )
        }
        await refreshGit()
    }

    private func applyVisibilityRules() {
        visibilityRulesRefreshTask?.cancel()
        refreshTask?.cancel()
        guard let workspaceURL else { return }
        let visibilityRules = settings.fileVisibilityRules
        visibilityRulesRefreshTask = Task { [weak self] in
            guard let self else { return }
            while isLoadingWorkspace, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.workspaceURL == workspaceURL else { return }
            if let localHistoryService {
                await localHistoryService.updateVisibilityRules(visibilityRules)
            }
            await rebuildWorkspace(
                at: workspaceURL,
                rules: visibilityRules,
                restartWatcher: true
            )
        }
    }

    private func recordSave(_ document: EditorDocument, previousText: String) {
        guard let localHistoryService else { return }
        let currentText = document.text
        let url = document.url
        Task(priority: .utility) {
            _ = try? await localHistoryService.record(text: previousText, for: url, reason: .saved)
            _ = try? await localHistoryService.record(text: currentText, for: url, reason: .saved)
        }
    }

    private func recordDiscardedEditorText(_ document: EditorDocument) {
        guard let localHistoryService else { return }
        let text = document.text
        let url = document.url
        Task(priority: .utility) {
            _ = try? await localHistoryService.record(text: text, for: url, reason: .unsavedDiscard)
        }
    }

    private func recordHistory(containedIn url: URL, reason: LocalHistoryReason) async {
        guard let localHistoryService else { return }
        let files: [URL]
        if projectFiles.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            files = [url]
        } else {
            files = projectFiles.filter { urlContains(url, child: $0) }
        }
        for fileURL in files {
            _ = try? await localHistoryService.recordFile(at: fileURL, reason: reason)
        }
    }

    private func reloadLocalHistory(selectNewest: Bool = false) async {
        guard let request = localHistoryRequest, let localHistoryService else {
            isLoadingLocalHistory = false
            return
        }
        do {
            localHistoryEntries = try await localHistoryService.entries(for: request.fileURL)
            if selectNewest || selectedLocalHistoryEntry == nil,
               let first = localHistoryEntries.first {
                selectLocalHistoryEntry(first)
            } else {
                isLoadingLocalHistory = false
            }
        } catch {
            localHistoryEntries = []
            localHistoryDiffRows = []
            isLoadingLocalHistory = false
        }
    }

    private func loadLocalHistoryDiff(for entry: LocalHistoryEntry) async {
        guard let request = localHistoryRequest,
              let localHistoryService,
              selectedLocalHistoryEntry?.id == entry.id else { return }
        do {
            let historicalText = try await localHistoryService.content(for: entry)
            let currentText: String
            if let document = openDocuments.first(where: { $0.url == request.fileURL }) {
                currentText = document.text
            } else {
                currentText = try String(contentsOf: request.fileURL, encoding: .utf8)
            }
            let rows = await Task.detached(priority: .userInitiated) {
                LocalHistoryDiffBuilder.rows(old: historicalText, current: currentText)
            }.value
            guard selectedLocalHistoryEntry?.id == entry.id else { return }
            localHistoryDiffRows = rows
        } catch {
            localHistoryDiffRows = []
        }
        isLoadingLocalHistory = false
    }

    private func reloadProjectLocalHistory(selectNewest: Bool = false) async {
        guard projectLocalHistoryRequest != nil, let localHistoryService else {
            isLoadingProjectLocalHistory = false
            return
        }
        do {
            projectLocalHistoryEntries = try await localHistoryService.allEntries()
            if selectNewest || selectedProjectLocalHistoryEntry == nil,
               let first = projectLocalHistoryEntries.first {
                selectProjectLocalHistoryEntry(first)
            } else {
                isLoadingProjectLocalHistory = false
            }
        } catch {
            projectLocalHistoryEntries = []
            selectedProjectLocalHistoryEntry = nil
            projectLocalHistoryDiffRows = []
            isLoadingProjectLocalHistory = false
        }
    }

    private func loadProjectLocalHistoryDiff(for entry: LocalHistoryEntry) async {
        guard projectLocalHistoryRequest != nil,
              let workspaceURL,
              let localHistoryService,
              selectedProjectLocalHistoryEntry?.id == entry.id else { return }

        let fileURL = workspaceURL
            .appendingPathComponent(entry.relativePath)
            .standardizedFileURL
        do {
            let historicalText = try await localHistoryService.content(for: entry)
            let currentText: String
            if let document = openDocuments.first(where: { $0.url == fileURL }) {
                currentText = document.text
            } else {
                currentText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            }
            let rows = await Task.detached(priority: .userInitiated) {
                LocalHistoryDiffBuilder.rows(old: historicalText, current: currentText)
            }.value
            guard selectedProjectLocalHistoryEntry?.id == entry.id else { return }
            projectLocalHistoryDiffRows = rows
        } catch {
            projectLocalHistoryDiffRows = []
        }
        isLoadingProjectLocalHistory = false
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

/// 监听本地 flagsChanged 事件，检测双击 Shift（两次按下间隔小于阈值）。
/// 事件回调运行在主线程事件循环；内部可变状态仅由主线程访问，
/// onDoubleTap 通过 @MainActor 闭包回到主隔离域。
final class DoubleShiftDetector: @unchecked Sendable {
    private static let threshold: TimeInterval = 0.35
    private var shiftWasDown = false
    private var lastShiftPress = Date.distantPast
    private let onDoubleTap: @MainActor () -> Void
    private var monitor: Any?

    init(onDoubleTap: @escaping @MainActor () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isShiftDown = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.shift)
            guard let self else { return event }
            if isShiftDown && !self.shiftWasDown {
                let now = Date()
                if now.timeIntervalSince(self.lastShiftPress) < Self.threshold {
                    self.lastShiftPress = .distantPast
                    Task { @MainActor in
                        self.onDoubleTap()
                    }
                } else {
                    self.lastShiftPress = now
                }
            }
            self.shiftWasDown = isShiftDown
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
