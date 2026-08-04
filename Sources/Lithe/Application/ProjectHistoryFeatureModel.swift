import Combine
import Foundation

/// Owns local-history state and the shared restore/diff workflow.
/// Platform composition only supplies storage and workspace operation ports.
@MainActor
final class ProjectHistoryFeatureModel: ObservableObject {
    struct Restoration: Sendable {
        let url: URL
        let documentID: UUID?
    }

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

    private let workspaceOperations: any WorkspaceOperations
    private let fileOperations: any WorkspaceFileOperations
    private let fileStorage: any FileStorage
    private let localHistoryOperations: any LocalHistoryOperations
    private var localHistoryService: LocalHistoryService?
    private var workspaceURLProvider: () -> URL?
    private var projectFilesProvider: () -> [URL]
    private var documentsProvider: () -> [EditorDocument]

    init(
        workspaceOperations: any WorkspaceOperations,
        fileOperations: any WorkspaceFileOperations,
        fileStorage: any FileStorage,
        localHistoryOperations: any LocalHistoryOperations,
        workspaceURLProvider: @escaping () -> URL? = { nil },
        projectFilesProvider: @escaping () -> [URL] = { [] },
        documentsProvider: @escaping () -> [EditorDocument] = { [] }
    ) {
        self.workspaceOperations = workspaceOperations
        self.fileOperations = fileOperations
        self.fileStorage = fileStorage
        self.localHistoryOperations = localHistoryOperations
        self.workspaceURLProvider = workspaceURLProvider
        self.projectFilesProvider = projectFilesProvider
        self.documentsProvider = documentsProvider
    }

    func configure(
        workspaceURLProvider: @escaping () -> URL?,
        projectFilesProvider: @escaping () -> [URL],
        documentsProvider: @escaping () -> [EditorDocument]
    ) {
        self.workspaceURLProvider = workspaceURLProvider
        self.projectFilesProvider = projectFilesProvider
        self.documentsProvider = documentsProvider
    }

    func openWorkspace(at workspaceURL: URL, visibilityRules: FileVisibilityRules) {
        localHistoryService = LocalHistoryService(
            workspaceURL: workspaceURL,
            visibilityRules: visibilityRules,
            storage: fileStorage,
            operations: localHistoryOperations
        )
    }

    func reset() {
        localHistoryService = nil
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
    }

    func updateVisibilityRules(_ rules: FileVisibilityRules) async {
        await localHistoryService?.updateVisibilityRules(rules)
    }

    func seed(files: [URL]) async {
        await localHistoryService?.seed(files: files)
    }

    func recordSave(_ document: EditorDocument, previousText: String) {
        guard let localHistoryService else { return }
        let currentText = document.text
        let url = document.url
        Task(priority: .utility) {
            _ = try? await localHistoryService.record(text: previousText, for: url, reason: .saved)
            _ = try? await localHistoryService.record(text: currentText, for: url, reason: .saved)
        }
    }

    func recordDiscardedEditorText(_ document: EditorDocument) {
        guard let localHistoryService else { return }
        let text = document.text
        let url = document.url
        Task(priority: .utility) {
            _ = try? await localHistoryService.record(text: text, for: url, reason: .unsavedDiscard)
        }
    }

    func recordHistorySnapshot(
        text: String,
        for fileURL: URL,
        reason: LocalHistoryReason
    ) async {
        _ = try? await localHistoryService?.record(text: text, for: fileURL, reason: reason)
    }

    func recordHistory(containedIn url: URL, reason: LocalHistoryReason) async {
        guard let localHistoryService else { return }
        let files: [URL]
        if projectFilesProvider().contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            files = [url]
        } else {
            files = projectFilesProvider().filter { urlContains(url, child: $0) }
        }
        for fileURL in files {
            _ = try? await localHistoryService.recordFile(at: fileURL, reason: reason)
        }
    }

    func relocateHistory(from sourceURL: URL, to destinationURL: URL) async {
        try? await localHistoryService?.relocateHistory(from: sourceURL, to: destinationURL)
    }

    func recordExternalChanges(_ paths: [URL]) {
        guard let localHistoryService else { return }
        let changedFiles = paths.filter { fileOperations.fileExists(at: $0) }
        Task(priority: .utility) {
            for fileURL in changedFiles {
                _ = try? await localHistoryService.recordFile(at: fileURL, reason: .externalChange)
            }
        }
    }

    func showLocalHistory(for fileURL: URL) {
        guard isWorkspaceURL(fileURL), WorkspaceTextFilePolicy.isReadableTextFile(fileURL) else { return }
        localHistoryRequest = LocalHistoryRequest(fileURL: fileURL.standardizedFileURL)
        localHistoryEntries = []
        selectedLocalHistoryEntry = nil
        localHistoryDiffRows = []
        isLoadingLocalHistory = true
        Task { await reloadLocalHistory() }
    }

    func showProjectLocalHistory() {
        guard workspaceURLProvider() != nil else { return }
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

    func restoreSelectedLocalHistoryEntry() async -> Restoration? {
        guard let request = localHistoryRequest,
              let entry = selectedLocalHistoryEntry,
              let localHistoryService,
              let workspaceURL = workspaceURLProvider(),
              let relativePath = workspaceRelativePath(for: request.fileURL, root: workspaceURL) else { return nil }
        do {
            let restoredText = try await localHistoryService.content(for: entry)
            let document = documentsProvider().first { $0.url == request.fileURL }
            if let document {
                _ = try? await localHistoryService.record(
                    text: document.text,
                    for: request.fileURL,
                    reason: .restored
                )
            } else {
                _ = try? await localHistoryService.recordFile(at: request.fileURL, reason: .restored)
            }
            guard workspaceOperations.writeFile(
                restoredText,
                at: workspaceURL,
                relativePath: relativePath
            ) else { return nil }
            try document?.reloadFromDisk()
            return Restoration(url: request.fileURL, documentID: document?.id)
        } catch {
            return nil
        }
    }

    func restoreSelectedProjectLocalHistoryEntry() async -> Restoration? {
        guard let entry = selectedProjectLocalHistoryEntry,
              let workspaceURL = workspaceURLProvider(),
              let localHistoryService else { return nil }
        let targetURL = workspaceURL
            .appendingPathComponent(entry.relativePath)
            .standardizedFileURL
        guard isWorkspaceURL(targetURL), WorkspaceTextFilePolicy.isReadableTextFile(targetURL),
              let relativePath = workspaceRelativePath(for: targetURL, root: workspaceURL) else { return nil }
        do {
            let restoredText = try await localHistoryService.content(for: entry)
            let document = documentsProvider().first { $0.url == targetURL }
            if let document {
                _ = try? await localHistoryService.record(
                    text: document.text,
                    for: targetURL,
                    reason: .restored
                )
            } else if fileOperations.fileExists(at: targetURL) {
                _ = try? await localHistoryService.recordFile(at: targetURL, reason: .restored)
            }
            guard workspaceOperations.writeFile(
                restoredText,
                at: workspaceURL,
                relativePath: relativePath
            ) else { return nil }
            try document?.reloadFromDisk()
            return Restoration(url: targetURL, documentID: document?.id)
        } catch {
            return nil
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
                selectedLocalHistoryEntry = first
                await loadLocalHistoryDiff(for: first)
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
            let currentText = try currentText(for: request.fileURL)
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
                selectedProjectLocalHistoryEntry = first
                await loadProjectLocalHistoryDiff(for: first)
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
              let workspaceURL = workspaceURLProvider(),
              let localHistoryService,
              selectedProjectLocalHistoryEntry?.id == entry.id else { return }
        let fileURL = workspaceURL.appendingPathComponent(entry.relativePath).standardizedFileURL
        do {
            let historicalText = try await localHistoryService.content(for: entry)
            let currentText = try currentText(for: fileURL)
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

    private func currentText(for url: URL) throws -> String {
        if let document = documentsProvider().first(where: { $0.url == url }) {
            return document.text
        }
        guard let workspaceURL = workspaceURLProvider(),
              let relativePath = workspaceRelativePath(for: url, root: workspaceURL),
              let text = workspaceOperations.readFile(at: workspaceURL, relativePath: relativePath) else {
            throw NSError(domain: "LitheWorkspace", code: 4)
        }
        return text
    }

    private func workspaceRelativePath(for url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func isWorkspaceURL(_ url: URL) -> Bool {
        guard let workspaceURL = workspaceURLProvider() else { return false }
        return urlContains(workspaceURL, child: url)
    }

    private func urlContains(_ parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
