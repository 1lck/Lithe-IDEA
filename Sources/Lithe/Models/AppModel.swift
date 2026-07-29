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
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects = RecentProjectsStore.remove(project, from: recentProjects)
    }

    func openFile(_ url: URL) {
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
