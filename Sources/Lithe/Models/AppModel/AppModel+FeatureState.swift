import Foundation
import LitheGitModule
import LitheLocalHistoryModule
import LitheSearchModule

extension AppModel {
    var springEndpoints: [SpringEndpoint] { springFeature.endpoints }
    var springBeans: [SpringBean] { springFeature.beans }
    var isIndexingSpring: Bool { springFeature.isIndexing }
    var rootNode: FileNode? { workspaceFeature.rootNode }
    var projectFiles: [URL] { workspaceFeature.projectFiles }
    var javaEnvironmentReport: JavaEnvironmentReport? {
        runtimeFeature.javaEnvironmentReport
    }

    var shouldShowJavaEnvironmentBanner: Bool {
        guard javaEnvironmentReport?.status.requiresAttention == true else { return false }
        return projectFiles.contains { $0.pathExtension.lowercased() == "java" }
            || hasMavenProject
            || activeDocument?.url.pathExtension.lowercased() == "java"
    }

    /// Maven is an optional build-system feature. Keeping this capability in
    /// the generic workspace projection lets the UI hide the Java-only tool
    /// window for Go, Python, Node, Rust, Gradle-only, and plain projects.
    var hasMavenProject: Bool {
        projectFiles.contains { $0.lastPathComponent.lowercased() == "pom.xml" }
    }

    var openDocuments: [EditorDocument] { documentFeature.openDocuments }
    var standaloneFileLoadState: StandaloneFileLoadState {
        documentFeature.standaloneFileLoadState
    }
    var projectTreeRevealRequest: ProjectTreeRevealRequest? {
        documentFeature.projectTreeRevealRequest
    }

    func canRevealInProjectTree(_ url: URL) -> Bool {
        projectTreeURL(for: url) != nil
    }

    func projectTreeURL(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return ProjectTreeLocator.matchingURL(for: url, among: projectFiles)
    }

    func revealInProjectTree(_ url: URL) {
        guard let treeURL = projectTreeURL(for: url) else {
            showNotification("This file is not in the current workspace")
            return
        }
        selectedSidebar = .project
        documentFeature.requestProjectTreeReveal(for: treeURL)
    }

    func consumeProjectTreeRevealRequest(id: UUID) {
        documentFeature.consumeProjectTreeRevealRequest(id: id)
    }

    var activeDocumentID: UUID? {
        get { documentFeature.activeDocumentID }
        set {
            let previousDocumentID = documentFeature.activeDocumentID
            documentFeature.activeDocumentID = newValue
            guard previousDocumentID != newValue else { return }
            activateCurrentDocumentLanguageServerIfAvailable()
        }
    }

    func moveOpenDocument(_ documentID: UUID, before targetDocumentID: UUID) {
        documentFeature.moveDocument(documentID, before: targetDocumentID)
    }

    func moveOpenDocument(_ documentID: UUID, after targetDocumentID: UUID) {
        documentFeature.moveDocument(documentID, after: targetDocumentID)
    }
    var pendingCloseDocument: EditorDocument? { documentFeature.pendingCloseDocument }
    var isPendingProjectClose: Bool { documentFeature.isPendingProjectClose }

    var gitChanges: [GitChange] { gitFeatureIfActive?.gitChanges ?? [] }
    var gitTreeStatusProjection: GitTreeStatusProjection {
        gitFeatureIfActive?.gitTreeStatus ?? GitTreeStatusProjection(changes: [])
    }
    func gitChange(for url: URL) -> GitChange? {
        guard let root = gitRepositoryRoot,
              let relativePath = workspaceRelativePath(for: url, root: root) else { return nil }
        return gitFeatureIfActive?.gitTreeStatus.change(relativePath: relativePath)
    }

    func gitTreeStatus(for url: URL, isDirectory: Bool) -> GitChangeKind? {
        guard let root = gitRepositoryRoot,
              let relativePath = workspaceRelativePath(for: url, root: root) else { return nil }
        return gitFeatureIfActive?.gitTreeStatus.kind(
            relativePath: relativePath,
            isDirectory: isDirectory
        )
    }
    func gitLineChangeMarkers(for url: URL) -> [GitLineChangeMarker]? {
        gitFeatureIfActive?.gitLineChangeMarkers[url.standardizedFileURL]
    }
    func effectiveStagingState(for change: GitChange) -> Bool {
        gitFeatureIfActive?.effectiveStagingState(for: change) ?? change.isStaged
    }
    var gitStashes: [GitStash] { gitFeatureIfActive?.gitStashes ?? [] }
    var gitShelves: [GitShelfEntry] { gitFeatureIfActive?.gitShelves ?? [] }
    var gitSaveChangesPolicy: GitSaveChangesPolicy { settings.gitSaveChangesPolicy }
    var isPerformingStashOperation: Bool { gitFeatureIfActive?.isPerformingStashOperation ?? false }
    var isPerformingShelfOperation: Bool { gitFeatureIfActive?.isPerformingShelfOperation ?? false }
    var gitOperationState: GitOperationState? { gitFeatureIfActive?.gitOperationState }
    var isResolvingGitOperation: Bool { gitFeatureIfActive?.isResolvingGitOperation ?? false }
    var gitRepositoryRoot: URL? { gitFeatureIfActive?.gitRepositoryRoot }
    var currentBranch: String { gitFeatureIfActive?.currentBranch ?? "No Git" }
    var selectedChange: GitChange? {
        get { gitFeatureIfActive?.selectedChange }
        set { gitFeatureIfActive?.selectedChange = newValue }
    }
    var diffRows: [DiffRow] { gitFeatureIfActive?.diffRows ?? [] }
    var diffHunks: [DiffHunk] { gitFeatureIfActive?.diffHunks ?? [] }
    var gitDiffWhitespaceMode: GitDiffWhitespaceMode {
        get { gitFeatureIfActive?.gitDiffWhitespaceMode ?? .doNotIgnore }
        set { gitFeatureIfActive?.gitDiffWhitespaceMode = newValue }
    }
    var isLoadingDiff: Bool { gitFeatureIfActive?.isLoadingDiff ?? false }
    var isRefreshingGit: Bool { gitFeatureIfActive?.isRefreshingGit ?? false }
    var pendingDiscardChange: GitChange? {
        get { gitFeatureIfActive?.pendingDiscardChange }
        set { gitFeatureIfActive?.pendingDiscardChange = newValue }
    }
    var pendingDiscardHunk: DiffHunkRequest? {
        get { gitFeatureIfActive?.pendingDiscardHunk }
        set { gitFeatureIfActive?.pendingDiscardHunk = newValue }
    }
    var pendingCheckoutConflict: GitCheckoutConflictRequest? {
        get { gitFeatureIfActive?.pendingCheckoutConflict }
        set { gitFeatureIfActive?.pendingCheckoutConflict = newValue }
    }

    var pendingPullStrategy: GitPullStrategyRequest? {
        get { gitFeatureIfActive?.pendingPullStrategy }
        set { gitFeatureIfActive?.pendingPullStrategy = newValue }
    }

    var pendingIntegrationConflict: GitIntegrationConflictRequest? {
        get { gitFeatureIfActive?.pendingIntegrationConflict }
        set { gitFeatureIfActive?.pendingIntegrationConflict = newValue }
    }
    var pendingConflictRollback: GitConflictRollbackRequest? {
        get { gitFeatureIfActive?.pendingConflictRollback }
        set { gitFeatureIfActive?.pendingConflictRollback = newValue }
    }
    var pendingStashRestoreConflict: GitStashRestoreConflictRequest? {
        gitFeatureIfActive?.pendingStashRestoreConflict
    }
    var isStashRestoreConflictNoticeVisible: Bool {
        gitFeatureIfActive?.isStashRestoreConflictNoticeVisible ?? false
    }
    var gitConflictFilterPaths: Set<String> {
        gitFeatureIfActive?.gitConflictFilterPaths ?? []
    }
    var requestedStashReference: String? {
        gitFeatureIfActive?.requestedStashReference
    }
    var isCommitting: Bool { gitFeatureIfActive?.isCommitting ?? false }
    var gitBlameLines: [URL: [GitBlameLine]] { gitFeatureIfActive?.gitBlameLines ?? [:] }
    var gitReferences: [GitReference] { gitFeatureIfActive?.gitReferences ?? [] }
    var gitCommits: [GitCommit] { gitFeatureIfActive?.gitCommits ?? [] }
    var gitLogMatchedCommitHashes: Set<String>? {
        gitFeatureIfActive?.gitLogMatchedCommitHashes
    }
    var isFilteringGitLog: Bool { gitFeatureIfActive?.isFilteringGitLog ?? false }
    var selectedGitReference: GitReference? {
        get { gitFeatureIfActive?.selectedGitReference }
        set { gitFeatureIfActive?.selectedGitReference = newValue }
    }
    var selectedGitCommit: GitCommit? {
        get { gitFeatureIfActive?.selectedGitCommit }
        set { gitFeatureIfActive?.selectedGitCommit = newValue }
    }
    var selectedGitCommitFiles: [GitCommitFile] { gitFeatureIfActive?.selectedGitCommitFiles ?? [] }
    var selectedGitCommitFile: GitCommitFile? {
        get { gitFeatureIfActive?.selectedGitCommitFile }
        set { gitFeatureIfActive?.selectedGitCommitFile = newValue }
    }
    var selectedGitCommitDiffContext: GitCommitDiffContext? {
        get { gitFeatureIfActive?.selectedGitCommitDiffContext }
        set { gitFeatureIfActive?.selectedGitCommitDiffContext = newValue }
    }
    var isLoadingGitHistory: Bool { gitFeatureIfActive?.isLoadingGitHistory ?? false }
    var isLoadingMoreGitHistory: Bool { gitFeatureIfActive?.isLoadingMoreGitHistory ?? false }
    var canLoadMoreGitHistory: Bool { gitFeatureIfActive?.canLoadMoreGitHistory ?? false }
    var branchComparison: GitBranchComparison? { gitFeatureIfActive?.branchComparison }
    var selectedBranchComparisonFile: GitBranchComparisonFile? {
        get { gitFeatureIfActive?.selectedBranchComparisonFile }
        set { gitFeatureIfActive?.selectedBranchComparisonFile = newValue }
    }
    var branchComparisonRows: [DiffRow] { gitFeatureIfActive?.branchComparisonRows ?? [] }
    var isLoadingBranchComparison: Bool { gitFeatureIfActive?.isLoadingBranchComparison ?? false }
    var isPerformingBranchOperation: Bool { gitFeatureIfActive?.isPerformingBranchOperation ?? false }
    var isCloningRepository: Bool { gitFeatureIfActive?.isCloningRepository ?? false }
    var languageNavigationResults: [LanguageNavigationLocation] {
        languageNavigationLocations
    }
    var languageNavigationKind: LanguageNavigationResultKind {
        languageNavigationResultKind
    }
    var isLoadingNavigation: Bool {
        isLoadingLanguageNavigation
    }
    var isLoadingWorkspace: Bool { workspaceFeature.isLoadingWorkspace }
    var isRefreshingWorkspace: Bool { workspaceFeature.isRefreshingWorkspace }
    var workspaceLoadErrorMessage: String? { workspaceFeature.loadErrorMessage }
    var searchResults: [FileSearchResult] { searchFeatureIfActive?.searchResults ?? [] }
    var isSearching: Bool { searchFeatureIfActive?.isSearching ?? false }
    var searchEverywhereResults: SearchEverywhereResults {
        searchFeatureIfActive?.searchEverywhereResults ?? SearchEverywhereResults()
    }
    var searchEverywhereActionMatches: [LitheAction] {
        LitheActionRegistry.actions(for: self).filter { $0.matches(searchEverywhereQuery) }
    }
    var isSearchingEverywhere: Bool { searchFeatureIfActive?.isSearchingEverywhere ?? false }
    var projectReplacementFiles: [ProjectReplacementFile] {
        searchFeatureIfActive?.projectReplacementFiles ?? []
    }
    var isLoadingProjectReplacement: Bool {
        searchFeatureIfActive?.isLoadingProjectReplacement ?? false
    }

    var localHistoryRequest: LocalHistoryRequest? {
        get { projectHistoryFeatureIfActive?.localHistoryRequest }
        set { projectHistoryFeatureIfActive?.localHistoryRequest = newValue }
    }
    var localHistoryEntries: [LocalHistoryEntry] { projectHistoryFeatureIfActive?.localHistoryEntries ?? [] }
    var selectedLocalHistoryEntry: LocalHistoryEntry? {
        get { projectHistoryFeatureIfActive?.selectedLocalHistoryEntry }
        set { projectHistoryFeatureIfActive?.selectedLocalHistoryEntry = newValue }
    }
    var localHistoryDiffRows: [DiffRow] { (projectHistoryFeatureIfActive?.localHistoryDiffRows ?? []).map(DiffRow.init) }
    var isLoadingLocalHistory: Bool { projectHistoryFeatureIfActive?.isLoadingLocalHistory ?? false }
    var projectLocalHistoryRequest: ProjectLocalHistoryRequest? {
        get { projectHistoryFeatureIfActive?.projectLocalHistoryRequest }
        set { projectHistoryFeatureIfActive?.projectLocalHistoryRequest = newValue }
    }
    var projectLocalHistoryEntries: [LocalHistoryEntry] {
        projectHistoryFeatureIfActive?.projectLocalHistoryEntries ?? []
    }
    var selectedProjectLocalHistoryEntry: LocalHistoryEntry? {
        get { projectHistoryFeatureIfActive?.selectedProjectLocalHistoryEntry }
        set { projectHistoryFeatureIfActive?.selectedProjectLocalHistoryEntry = newValue }
    }
    var projectLocalHistoryDiffRows: [DiffRow] { (projectHistoryFeatureIfActive?.projectLocalHistoryDiffRows ?? []).map(DiffRow.init) }
    var isLoadingProjectLocalHistory: Bool {
        projectHistoryFeatureIfActive?.isLoadingProjectLocalHistory ?? false
    }

    func performShortcutCommand(id: String) {
        guard canPerformShortcutCommand(id: id) else { return }
        switch id {
        case "save":
            saveActiveDocument()
        case "search-everywhere":
            toggleSearchEverywhere()
        case "navigate-back":
            navigateBack()
        case "navigate-forward":
            navigateForward()
        case "find-next":
            navigateFind(offset: 1)
        case "find-previous":
            navigateFind(offset: -1)
        case "go-to-implementation":
            goToImplementation()
        default:
            LitheActionRegistry.actions(for: self).first { $0.id == id }?.perform()
        }
    }

    func canPerformShortcutCommand(id: String) -> Bool {
        switch id {
        case "open-project", "settings":
            true
        case "save", "find-in-file", "local-history", "reveal-in-finder":
            activeDocument != nil
        case "find-next", "find-previous":
            isFindBarVisible && findMatchCount > 0
        case "navigate-back":
            canNavigateBack
        case "navigate-forward":
            canNavigateForward
        case "go-to-definition":
            activeDocument.map { springFeature.handles($0.url) } == true
                || supportsLanguageServerFeature(.definition)
        case "find-usages":
            supportsLanguageServerFeature(.references)
        case "go-to-implementation":
            supportsLanguageServerFeature(.implementation)
        case "close-project", "search-everywhere", "search-in-project",
             "replace-in-project", "project-local-history", "run", "debug",
             "stop-run", "stop-debug", "toggle-terminal", "toggle-problems",
             "toggle-maven", "toggle-git-log", "toggle-run", "toggle-tests",
             "toggle-debug", "spring-endpoints":
            workspaceURL != nil
        default:
            false
        }
    }
}
