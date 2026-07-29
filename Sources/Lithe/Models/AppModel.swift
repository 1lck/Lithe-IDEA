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
    @Published private(set) var isRefreshingGit = false
    @Published var pendingDiscardChange: GitChange?
    @Published var commitMessage = ""
    @Published private(set) var isCommitting = false
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
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects = RecentProjectsStore.remove(project, from: recentProjects)
    }

    func openFile(_ url: URL) {
        selectedChange = nil
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
        selectedChange = change
        activeDocumentID = nil
        diffRows = []
        Task {
            diffRows = await GitService.diff(for: change)
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
            }
        } else {
            gitRepositoryRoot = nil
            currentBranch = "No Git"
            gitChanges = []
            selectedChange = nil
            diffRows = []
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
        let result = await GitService.commit(at: gitRepositoryRoot, message: message)
        isCommitting = false
        if result.succeeded {
            commitMessage = ""
            showNotification("Changes committed")
        } else {
            showNotification(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
        case .changes: "arrow.triangle.branch"
        case .search: "magnifyingglass"
        }
    }
}
