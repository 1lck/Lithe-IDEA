import Combine
import Foundation

/// One editor comparison. Git services and mutation workflows remain feature-owned;
/// buffers and request generations belong to the tab, including in inactive splits.
@MainActor
package final class GitRepositoryDiffSession: ObservableObject, Identifiable {
    package let id: UUID
    @Published package var selectedChange: GitChange?
    @Published package var selectedDiffPatch = ""
    @Published package var diffRows: [DiffRow] = []
    @Published package var diffHunks: [DiffHunk] = []
    @Published package var gitDiffWhitespaceMode = GitDiffWhitespaceMode.doNotIgnore
    @Published package var isLoadingDiff = false
    @Published package var selectedGitCommitFile: GitCommitFile?
    @Published package var selectedGitCommitDiffContext: GitCommitDiffContext?
    @Published package var branchComparison: GitBranchComparison?
    @Published package var selectedBranchComparisonFile: GitBranchComparisonFile?
    @Published package var branchComparisonRows: [DiffRow] = []
    @Published package var isLoadingBranchComparison = false
    package var savedDiffSnapshot: GitSavedChangesSnapshot?
    package var savedDiffVersion: String?
    package var commitFiles: [GitCommitFile] = []
    package var directoryURL: URL?
    package var comparisonRoot: URL?
    var repositoryDiffGeneration = UUID()
    package private(set) var isClosed = false

    package init(id: UUID = UUID()) { self.id = id }

    func reset() {
        repositoryDiffGeneration = UUID()
        selectedChange = nil
        selectedDiffPatch = ""
        diffRows = []
        diffHunks = []
        isLoadingDiff = false
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
        savedDiffSnapshot = nil
        savedDiffVersion = nil
        commitFiles = []
        directoryURL = nil
        comparisonRoot = nil
    }

    func close() {
        isClosed = true
        reset()
    }
}
