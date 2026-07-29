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
    @Published var projectItemEditRequest: ProjectItemEditRequest?
    @Published var pendingProjectItemDeletion: ProjectItemDeletionRequest?
    @Published private(set) var isPerformingProjectItemOperation = false
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

    var currentGitReference: GitReference? {
        gitReferences.first(where: \.isCurrent)
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
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = false
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
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = false
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

    func refreshWorkspace() async {
        guard let workspaceURL, !isLoadingWorkspace else { return }
        isLoadingWorkspace = true
        let snapshot = await Task.detached(priority: .userInitiated) {
            WorkspaceScanner.snapshot(at: workspaceURL)
        }.value
        guard self.workspaceURL == workspaceURL else { return }
        rootNode = snapshot.root
        projectFiles = snapshot.files
        isLoadingWorkspace = false
        await refreshGit()
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
