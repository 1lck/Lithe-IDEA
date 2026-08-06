import Foundation

extension AppModel {
    var rootNode: FileNode? { workspaceFeature.rootNode }
    var projectFiles: [URL] { workspaceFeature.projectFiles }

    var openDocuments: [EditorDocument] { documentFeature.openDocuments }
    var activeDocumentID: UUID? {
        get { documentFeature.activeDocumentID }
        set { documentFeature.activeDocumentID = newValue }
    }
    var pendingCloseDocument: EditorDocument? { documentFeature.pendingCloseDocument }
    var isPendingProjectClose: Bool { documentFeature.isPendingProjectClose }

    var gitChanges: [GitChange] { gitFeature.gitChanges }
    var gitStashes: [GitStash] { gitFeature.gitStashes }
    var isPerformingStashOperation: Bool { gitFeature.isPerformingStashOperation }
    var gitRepositoryRoot: URL? { gitFeature.gitRepositoryRoot }
    var currentBranch: String { gitFeature.currentBranch }
    var selectedChange: GitChange? {
        get { gitFeature.selectedChange }
        set { gitFeature.selectedChange = newValue }
    }
    var diffRows: [DiffRow] { gitFeature.diffRows }
    var diffHunks: [DiffHunk] { gitFeature.diffHunks }
    var gitDiffWhitespaceMode: GitDiffWhitespaceMode {
        get { gitFeature.gitDiffWhitespaceMode }
        set { gitFeature.gitDiffWhitespaceMode = newValue }
    }
    var isLoadingDiff: Bool { gitFeature.isLoadingDiff }
    var isRefreshingGit: Bool { gitFeature.isRefreshingGit }
    var pendingDiscardChange: GitChange? {
        get { gitFeature.pendingDiscardChange }
        set { gitFeature.pendingDiscardChange = newValue }
    }
    var pendingDiscardHunk: DiffHunkRequest? {
        get { gitFeature.pendingDiscardHunk }
        set { gitFeature.pendingDiscardHunk = newValue }
    }
    var isCommitting: Bool { gitFeature.isCommitting }
    var gitBlameLines: [URL: [GitBlameLine]] { gitFeature.gitBlameLines }
    var gitReferences: [GitReference] { gitFeature.gitReferences }
    var gitCommits: [GitCommit] { gitFeature.gitCommits }
    var selectedGitReference: GitReference? {
        get { gitFeature.selectedGitReference }
        set { gitFeature.selectedGitReference = newValue }
    }
    var selectedGitCommit: GitCommit? {
        get { gitFeature.selectedGitCommit }
        set { gitFeature.selectedGitCommit = newValue }
    }
    var selectedGitCommitFiles: [GitCommitFile] { gitFeature.selectedGitCommitFiles }
    var selectedGitCommitFile: GitCommitFile? {
        get { gitFeature.selectedGitCommitFile }
        set { gitFeature.selectedGitCommitFile = newValue }
    }
    var selectedGitCommitDiffContext: GitCommitDiffContext? {
        get { gitFeature.selectedGitCommitDiffContext }
        set { gitFeature.selectedGitCommitDiffContext = newValue }
    }
    var isLoadingGitHistory: Bool { gitFeature.isLoadingGitHistory }
    var isLoadingMoreGitHistory: Bool { gitFeature.isLoadingMoreGitHistory }
    var canLoadMoreGitHistory: Bool { gitFeature.canLoadMoreGitHistory }
    var branchComparison: GitBranchComparison? { gitFeature.branchComparison }
    var selectedBranchComparisonFile: GitBranchComparisonFile? {
        get { gitFeature.selectedBranchComparisonFile }
        set { gitFeature.selectedBranchComparisonFile = newValue }
    }
    var branchComparisonRows: [DiffRow] { gitFeature.branchComparisonRows }
    var isLoadingBranchComparison: Bool { gitFeature.isLoadingBranchComparison }
    var isPerformingBranchOperation: Bool { gitFeature.isPerformingBranchOperation }
    var isCloningRepository: Bool { gitFeature.isCloningRepository }
    var javaNavigationLocations: [JavaNavigationLocation] { javaFeature.javaNavigationLocations }
    var javaNavigationResultKind: JavaNavigationResultKind { javaFeature.javaNavigationResultKind }
    var isLoadingJavaNavigation: Bool { javaFeature.isLoadingJavaNavigation }
    var javaDiagnostics: [URL: [JavaDiagnostic]] { javaFeature.javaDiagnostics }

    var isLoadingWorkspace: Bool { workspaceFeature.isLoadingWorkspace }
    var isRefreshingWorkspace: Bool { workspaceFeature.isRefreshingWorkspace }
    var searchResults: [FileSearchResult] { searchFeature.searchResults }
    var isSearching: Bool { searchFeature.isSearching }
    var searchEverywhereResults: SearchEverywhereResults { searchFeature.searchEverywhereResults }
    var isSearchingEverywhere: Bool { searchFeature.isSearchingEverywhere }
    var projectReplacementFiles: [ProjectReplacementFile] { searchFeature.projectReplacementFiles }
    var isLoadingProjectReplacement: Bool { searchFeature.isLoadingProjectReplacement }

    var localHistoryRequest: LocalHistoryRequest? {
        get { projectHistoryFeature.localHistoryRequest }
        set { projectHistoryFeature.localHistoryRequest = newValue }
    }
    var localHistoryEntries: [LocalHistoryEntry] { projectHistoryFeature.localHistoryEntries }
    var selectedLocalHistoryEntry: LocalHistoryEntry? {
        get { projectHistoryFeature.selectedLocalHistoryEntry }
        set { projectHistoryFeature.selectedLocalHistoryEntry = newValue }
    }
    var localHistoryDiffRows: [DiffRow] { projectHistoryFeature.localHistoryDiffRows }
    var isLoadingLocalHistory: Bool { projectHistoryFeature.isLoadingLocalHistory }
    var projectLocalHistoryRequest: ProjectLocalHistoryRequest? {
        get { projectHistoryFeature.projectLocalHistoryRequest }
        set { projectHistoryFeature.projectLocalHistoryRequest = newValue }
    }
    var projectLocalHistoryEntries: [LocalHistoryEntry] {
        projectHistoryFeature.projectLocalHistoryEntries
    }
    var selectedProjectLocalHistoryEntry: LocalHistoryEntry? {
        get { projectHistoryFeature.selectedProjectLocalHistoryEntry }
        set { projectHistoryFeature.selectedProjectLocalHistoryEntry = newValue }
    }
    var projectLocalHistoryDiffRows: [DiffRow] { projectHistoryFeature.projectLocalHistoryDiffRows }
    var isLoadingProjectLocalHistory: Bool {
        projectHistoryFeature.isLoadingProjectLocalHistory
    }
}
