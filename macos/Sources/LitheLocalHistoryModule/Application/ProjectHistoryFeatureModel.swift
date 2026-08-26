import Combine
import Foundation

/// Owns local-history state and the shared restore/diff workflow.
/// Platform composition only supplies storage and workspace operation ports.
@MainActor
public final class ProjectHistoryFeatureModel: ObservableObject {
    public struct Restoration: Sendable {
        public let url: URL
        public let documentID: UUID?
    }

    @Published public var localHistoryRequest: LocalHistoryRequest?
    @Published public private(set) var localHistoryEntries: [LocalHistoryEntry] = []
    @Published public var selectedLocalHistoryEntry: LocalHistoryEntry?
    @Published public private(set) var localHistoryDiffRows: [LocalHistoryDiffRow] = []
    @Published public private(set) var isLoadingLocalHistory = false

    @Published public var projectLocalHistoryRequest: ProjectLocalHistoryRequest?
    @Published public private(set) var projectLocalHistoryEntries: [LocalHistoryEntry] = []
    @Published public var selectedProjectLocalHistoryEntry: LocalHistoryEntry?
    @Published public private(set) var projectLocalHistoryDiffRows: [LocalHistoryDiffRow] = []
    @Published public private(set) var isLoadingProjectLocalHistory = false

    private let workspaceAccess: any LocalHistoryWorkspaceAccess
    private let storage: any LocalHistoryStorage
    private let localHistoryOperations: any LocalHistoryOperations
    private var localHistoryService: LocalHistoryService?
    private var seedTask: Task<Void, Never>?
    private var localHistoryTask: Task<Void, Never>?
    private var projectHistoryTask: Task<Void, Never>?
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var workspaceURLProvider: () -> URL?
    private var projectFilesProvider: () -> [URL]
    private var documentsProvider: () -> [LocalHistoryDocumentSnapshot]

    public var hasActiveModuleWork: Bool {
        isLoadingLocalHistory || isLoadingProjectLocalHistory || seedTask != nil || !backgroundTasks.isEmpty
    }

    public init(
        workspaceAccess: any LocalHistoryWorkspaceAccess,
        storage: any LocalHistoryStorage,
        localHistoryOperations: any LocalHistoryOperations,
        workspaceURLProvider: @escaping () -> URL? = { nil },
        projectFilesProvider: @escaping () -> [URL] = { [] },
        documentsProvider: @escaping () -> [LocalHistoryDocumentSnapshot] = { [] }
    ) {
        self.workspaceAccess = workspaceAccess
        self.storage = storage
        self.localHistoryOperations = localHistoryOperations
        self.workspaceURLProvider = workspaceURLProvider
        self.projectFilesProvider = projectFilesProvider
        self.documentsProvider = documentsProvider
    }

    public func configure(
        workspaceURLProvider: @escaping () -> URL?,
        projectFilesProvider: @escaping () -> [URL],
        documentsProvider: @escaping () -> [LocalHistoryDocumentSnapshot]
    ) {
        self.workspaceURLProvider = workspaceURLProvider
        self.projectFilesProvider = projectFilesProvider
        self.documentsProvider = documentsProvider
    }

    public func openWorkspace(at workspaceURL: URL, visibilityRules: LocalHistoryVisibilityRules) {
        localHistoryService = LocalHistoryService(
            workspaceURL: workspaceURL,
            visibilityRules: visibilityRules,
            storage: storage,
            operations: localHistoryOperations
        )
    }

    public func reset() {
        seedTask?.cancel()
        seedTask = nil
        localHistoryTask?.cancel()
        localHistoryTask = nil
        projectHistoryTask?.cancel()
        projectHistoryTask = nil
        backgroundTasks.values.forEach { $0.cancel() }
        backgroundTasks.removeAll()
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

    public func updateVisibilityRules(_ rules: LocalHistoryVisibilityRules) async {
        await localHistoryService?.updateVisibilityRules(rules)
    }

    public func seed(files: [URL]) {
        seedTask?.cancel()
        guard let localHistoryService else { return }
        seedTask = Task { [weak self] in
            await localHistoryService.seed(files: files)
            guard !Task.isCancelled else { return }
            self?.seedTask = nil
        }
    }

    public func recordSave(_ document: LocalHistoryDocumentSnapshot, previousText: String) {
        guard let localHistoryService else { return }
        let currentText = document.text
        let url = document.url
        startBackgroundTask {
            _ = try? await localHistoryService.record(text: previousText, for: url, reason: .saved)
            _ = try? await localHistoryService.record(text: currentText, for: url, reason: .saved)
        }
    }

    public func recordDiscardedEditorText(_ document: LocalHistoryDocumentSnapshot) {
        guard let localHistoryService else { return }
        let text = document.text
        let url = document.url
        startBackgroundTask {
            _ = try? await localHistoryService.record(text: text, for: url, reason: .unsavedDiscard)
        }
    }

    public func recordHistorySnapshot(
        text: String,
        for fileURL: URL,
        reason: LocalHistoryReason
    ) async {
        _ = try? await localHistoryService?.record(text: text, for: fileURL, reason: reason)
    }

    public func recordHistory(containedIn url: URL, reason: LocalHistoryReason) async {
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

    public func relocateHistory(from sourceURL: URL, to destinationURL: URL) async {
        try? await localHistoryService?.relocateHistory(from: sourceURL, to: destinationURL)
    }

    public func recordExternalChanges(_ paths: [URL]) {
        guard let localHistoryService else { return }
        let changedFiles = paths.filter { workspaceAccess.fileExists(at: $0) }
        startBackgroundTask {
            for fileURL in changedFiles {
                _ = try? await localHistoryService.recordFile(at: fileURL, reason: .externalChange)
            }
        }
    }

    private func startBackgroundTask(
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let id = UUID()
        backgroundTasks[id] = Task(priority: .utility) { [weak self] in
            await operation()
            self?.backgroundTasks[id] = nil
        }
    }

    public func showLocalHistory(for fileURL: URL) {
        guard isWorkspaceURL(fileURL) else { return }
        localHistoryRequest = LocalHistoryRequest(fileURL: fileURL.standardizedFileURL)
        localHistoryEntries = []
        selectedLocalHistoryEntry = nil
        localHistoryDiffRows = []
        isLoadingLocalHistory = true
        localHistoryTask?.cancel()
        localHistoryTask = Task { [weak self] in await self?.reloadLocalHistory() }
    }

    public func showProjectLocalHistory() {
        guard workspaceURLProvider() != nil else { return }
        projectLocalHistoryRequest = ProjectLocalHistoryRequest()
        projectLocalHistoryEntries = []
        selectedProjectLocalHistoryEntry = nil
        projectLocalHistoryDiffRows = []
        isLoadingProjectLocalHistory = true
        projectHistoryTask?.cancel()
        projectHistoryTask = Task { [weak self] in await self?.reloadProjectLocalHistory() }
    }

    public func selectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        selectedLocalHistoryEntry = entry
        localHistoryDiffRows = []
        isLoadingLocalHistory = true
        localHistoryTask?.cancel()
        localHistoryTask = Task { [weak self] in await self?.loadLocalHistoryDiff(for: entry) }
    }

    public func selectProjectLocalHistoryEntry(_ entry: LocalHistoryEntry) {
        selectedProjectLocalHistoryEntry = entry
        projectLocalHistoryDiffRows = []
        isLoadingProjectLocalHistory = true
        projectHistoryTask?.cancel()
        projectHistoryTask = Task { [weak self] in await self?.loadProjectLocalHistoryDiff(for: entry) }
    }

    public func refreshLocalHistory() async {
        isLoadingLocalHistory = true
        await reloadLocalHistory()
        if let selectedLocalHistoryEntry {
            await loadLocalHistoryDiff(for: selectedLocalHistoryEntry)
        }
    }

    public func refreshProjectLocalHistory() async {
        isLoadingProjectLocalHistory = true
        await reloadProjectLocalHistory()
        if let selectedProjectLocalHistoryEntry {
            await loadProjectLocalHistoryDiff(for: selectedProjectLocalHistoryEntry)
        }
    }

    public func restoreSelectedLocalHistoryEntry() async -> Restoration? {
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
            guard workspaceAccess.writeFile(
                restoredText,
                at: workspaceURL,
                relativePath: relativePath
            ) else { return nil }
            return Restoration(url: request.fileURL, documentID: document?.id)
        } catch {
            return nil
        }
    }

    public func restoreSelectedProjectLocalHistoryEntry() async -> Restoration? {
        guard let entry = selectedProjectLocalHistoryEntry,
              let workspaceURL = workspaceURLProvider(),
              let localHistoryService else { return nil }
        let targetURL = workspaceURL
            .appendingPathComponent(entry.relativePath)
            .standardizedFileURL
        guard isWorkspaceURL(targetURL),
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
            } else if workspaceAccess.fileExists(at: targetURL) {
                _ = try? await localHistoryService.recordFile(at: targetURL, reason: .restored)
            }
            guard workspaceAccess.writeFile(
                restoredText,
                at: workspaceURL,
                relativePath: relativePath
            ) else { return nil }
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
              let text = workspaceAccess.readFile(at: workspaceURL, relativePath: relativePath) else {
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
