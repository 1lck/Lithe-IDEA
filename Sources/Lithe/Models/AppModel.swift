import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published var selectedSidebar: SidebarDestination = .project
    @Published var isRunPlaceholderPresented = false
    @Published private(set) var recentProjects: [RecentProject]
    @Published private(set) var rootNode: FileNode?
    @Published private(set) var projectFiles: [URL] = []
    @Published private(set) var openDocuments: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [FileSearchResult] = []
    @Published private(set) var isLoadingWorkspace = false
    @Published private(set) var isSearching = false
    @Published var pendingCloseDocument: EditorDocument?
    @Published var notificationMessage: String?
    @Published private(set) var gitChanges: [GitChange] = []
    @Published private(set) var gitRepositoryRoot: URL?
    @Published private(set) var currentBranch = "No Git"
    @Published var selectedChange: GitChange?
    @Published private(set) var diffRows: [DiffRow] = []
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var isRefreshingGit = false
    @Published var pendingDiscardChange: GitChange?
    @Published var commitMessage = ""
    @Published var amendCommit = false
    @Published private(set) var isCommitting = false
    @Published var isGitLogVisible = false
    @Published private(set) var gitReferences: [GitReference] = []
    @Published private(set) var gitCommits: [GitCommit] = []
    @Published var selectedGitReference: GitReference?
    @Published var selectedGitCommit: GitCommit?
    @Published private(set) var selectedGitCommitFiles: [GitCommitFile] = []
    @Published var selectedGitCommitFile: GitCommitFile?
    @Published var gitLogSearchQuery = ""
    @Published private(set) var isLoadingGitHistory = false
    @Published private(set) var branchComparison: GitBranchComparison?
    @Published var selectedBranchComparisonFile: GitBranchComparisonFile?
    @Published private(set) var branchComparisonRows: [DiffRow] = []
    @Published private(set) var isLoadingBranchComparison = false
    @Published private(set) var isPerformingBranchOperation = false
    private var directoryWatcher: DirectoryWatcher?
    private var refreshTask: Task<Void, Never>?

    init() {
        recentProjects = RecentProjectsStore.load()
    }

    var projectName: String {
        workspaceURL?.lastPathComponent ?? "Lithe"
    }

    var activeDocument: EditorDocument? {
        guard let activeDocumentID else { return nil }
        return openDocuments.first { $0.id == activeDocumentID }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open a project"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func openProject(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        workspaceURL = normalizedURL
        selectedSidebar = .project
        rootNode = nil
        projectFiles = []
        openDocuments = []
        activeDocumentID = nil
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        recentProjects = RecentProjectsStore.record(normalizedURL, in: recentProjects)
        isLoadingWorkspace = true

        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                WorkspaceScanner.snapshot(at: normalizedURL)
            }.value
            guard workspaceURL == normalizedURL else { return }
            rootNode = snapshot.root
            projectFiles = snapshot.files
            isLoadingWorkspace = false
            await refreshGit()
            startWatching(normalizedURL)
        }
    }

    func closeProject() {
        workspaceURL = nil
        selectedSidebar = .project
        rootNode = nil
        projectFiles = []
        openDocuments = []
        activeDocumentID = nil
        searchResults = []
        searchQuery = ""
        directoryWatcher?.stop()
        directoryWatcher = nil
        refreshTask?.cancel()
        gitChanges = []
        gitRepositoryRoot = nil
        currentBranch = "No Git"
        selectedChange = nil
        diffRows = []
        isLoadingDiff = false
        isGitLogVisible = false
        gitReferences = []
        gitCommits = []
        selectedGitReference = nil
        selectedGitCommit = nil
        selectedGitCommitFiles = []
        selectedGitCommitFile = nil
        gitLogSearchQuery = ""
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
        isPerformingBranchOperation = false
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects = RecentProjectsStore.remove(project, from: recentProjects)
    }

    func openFile(_ url: URL) {
        selectedChange = nil
        closeBranchComparison()
        let normalizedURL = url.standardizedFileURL
        if let existing = openDocuments.first(where: { $0.url == normalizedURL }) {
            activeDocumentID = existing.id
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
            modificationDate: EditorDocument.modificationDate(for: normalizedURL)
        )
        openDocuments.append(document)
        activeDocumentID = document.id
    }

    func requestCloseDocument(_ document: EditorDocument) {
        if document.isDirty {
            pendingCloseDocument = document
        } else {
            closeDocument(document)
        }
    }

    func closePendingDocument(discardingChanges: Bool) {
        guard let document = pendingCloseDocument else { return }
        if !discardingChanges {
            do {
                try document.save()
            } catch {
                showNotification("Could not save \(document.url.lastPathComponent)")
                return
            }
        }
        pendingCloseDocument = nil
        closeDocument(document)
    }

    func cancelPendingClose() {
        pendingCloseDocument = nil
    }

    func saveActiveDocument() {
        guard let document = activeDocument else { return }
        do {
            try document.save()
            showNotification("Saved \(document.url.lastPathComponent)")
        } catch {
            showNotification("Could not save \(document.url.lastPathComponent)")
        }
    }

    func searchProject() async {
        guard let workspaceURL else { return }
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let files = projectFiles
        let results = await Task.detached(priority: .userInitiated) {
            WorkspaceScanner.search(query: query, root: workspaceURL, files: files)
        }.value
        guard searchQuery == query else { return }
        searchResults = results
        isSearching = false
    }

    func selectChange(_ change: GitChange) {
        closeBranchComparison()
        selectedChange = change
        activeDocumentID = nil
        diffRows = []
        isLoadingDiff = true
        Task {
            diffRows = await GitService.diff(for: change)
            isLoadingDiff = false
        }
    }

    func refreshGit() async {
        guard let workspaceURL, !isRefreshingGit else { return }
        isRefreshingGit = true
        defer { isRefreshingGit = false }

        if let snapshot = await GitService.snapshot(for: workspaceURL) {
            gitRepositoryRoot = snapshot.repositoryRoot
            currentBranch = snapshot.branch
            gitChanges = snapshot.changes
            if let selectedChange,
               let updated = snapshot.changes.first(where: { $0.path == selectedChange.path }) {
                self.selectedChange = updated
                diffRows = await GitService.diff(for: updated)
            } else if selectedChange != nil {
                self.selectedChange = nil
                diffRows = []
                isLoadingDiff = false
            }
        } else {
            gitRepositoryRoot = nil
            currentBranch = "No Git"
            gitChanges = []
            selectedChange = nil
            diffRows = []
            isLoadingDiff = false
        }

        if isGitLogVisible {
            await refreshGitHistory()
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

    func showPushPlaceholder() {
        showNotification("Push is intentionally not connected in this release")
    }

    func toggleGitLog() async {
        isGitLogVisible.toggle()
        if isGitLogVisible && gitCommits.isEmpty {
            await refreshGitHistory()
        }
    }

    func closeGitLog() {
        isGitLogVisible = false
    }

    func selectGitReference(_ reference: GitReference?) async {
        selectedGitReference = reference
        await refreshGitHistory()
    }

    func refreshGitHistory() async {
        guard let gitRepositoryRoot, !isLoadingGitHistory else { return }
        isLoadingGitHistory = true
        let previousCommitHash = selectedGitCommit?.hash
        let snapshot = await GitService.history(at: gitRepositoryRoot, reference: selectedGitReference)
        gitReferences = snapshot.references
        gitCommits = snapshot.commits

        let nextCommit = snapshot.commits.first(where: { $0.hash == previousCommitHash }) ?? snapshot.commits.first
        isLoadingGitHistory = false
        if let nextCommit {
            await selectGitCommit(nextCommit)
        } else {
            selectedGitCommit = nil
            selectedGitCommitFiles = []
            selectedGitCommitFile = nil
        }
    }

    func selectGitCommit(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommit = commit
        selectedGitCommitFile = nil
        let files = await GitService.files(in: commit, at: gitRepositoryRoot)
        guard selectedGitCommit?.hash == commit.hash else { return }
        selectedGitCommitFiles = files
        selectedGitCommitFile = files.first
    }

    func showComparisonWithWorkingTree(for reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
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
        let wasActive = activeDocumentID == document.id
        openDocuments.remove(at: index)
        if wasActive {
            if openDocuments.indices.contains(index) {
                activeDocumentID = openDocuments[index].id
            } else {
                activeDocumentID = openDocuments.last?.id
            }
        }
    }

    private func startWatching(_ url: URL) {
        directoryWatcher?.stop()
        directoryWatcher = DirectoryWatcher(root: url) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.scheduleExternalRefresh(paths: paths)
            }
        }
        directoryWatcher?.start()
    }

    private func scheduleExternalRefresh(paths: [String]) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let workspaceURL else { return }

            var conflictDetected = false
            for document in openDocuments where paths.contains(where: { $0 == document.url.path }) {
                if document.processPossibleExternalChange(), document.hasExternalConflict {
                    conflictDetected = true
                }
            }
            if conflictDetected {
                showNotification("External edits conflict with unsaved changes")
            }

            let snapshot = await Task.detached(priority: .utility) {
                WorkspaceScanner.snapshot(at: workspaceURL)
            }.value
            guard self.workspaceURL == workspaceURL else { return }
            rootNode = snapshot.root
            projectFiles = snapshot.files
            await refreshGit()
        }
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
}
