import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Confirmation and editor safety shared by Git and plugin Commit menus.
/// Providers own tracked deletion; native Trash owns ordinary disk deletion.
@MainActor
final class CommitFileDeletionFeatureModel: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let urls: [URL]
        let root: URL
        let usesVcs: Bool
        let isCurrent: @MainActor () -> Bool
        let isEligible: @MainActor () -> Bool
        let delete: @MainActor ([URL]) async -> Bool
        let refresh: @MainActor () async -> Void
    }

    @Published private(set) var pending: Request?
    @Published private(set) var isDeleting = false
    private var deletionTask: Task<Void, Never>?
    private let files: any WorkspaceFileOperations
    private let hasUnsavedEdits: @MainActor (URL) -> Bool
    private let closeCleanDocuments: @MainActor (URL) -> Void
    private let notify: @MainActor (String) -> Void
    private let synchronizeEditors: @MainActor ([URL]) async throws -> Void

    init(files: any WorkspaceFileOperations,
         hasUnsavedEdits: @escaping @MainActor (URL) -> Bool,
         closeCleanDocuments: @escaping @MainActor (URL) -> Void,
         synchronizeEditors: @escaping @MainActor ([URL]) async throws -> Void = { _ in },
         notify: @escaping @MainActor (String) -> Void) {
        self.files = files
        self.hasUnsavedEdits = hasUnsavedEdits
        self.closeCleanDocuments = closeCleanDocuments
        self.notify = notify
        self.synchronizeEditors = synchronizeEditors
    }

    func request(_ urls: [URL], root: URL, usesVcs: Bool = false,
                 isCurrent: @escaping @MainActor () -> Bool,
                 isEligible: @escaping @MainActor () -> Bool = { true },
                 delete: (@MainActor ([URL]) async -> Bool)? = nil,
                 refresh: @escaping @MainActor () async -> Void) {
        guard !isDeleting, isCurrent(), isEligible() else { return }
        let root = root.standardizedFileURL
        let urls = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !urls.isEmpty, urls.allSatisfy({ contains($0, in: root) && files.fileExists(at: $0) }) else { return }
        let targets = urls.filter { url in !urls.contains { $0 != url && url.path.hasPrefix($0.path + "/") } }
        guard !targets.contains(where: hasUnsavedEdits) else { reportUnsaved(); return }
        pending = Request(urls: targets, root: root, usesVcs: usesVcs, isCurrent: isCurrent, isEligible: isEligible,
                          delete: delete ?? { [weak self] urls in
                              await self?.trash(urls, root: root, isCurrent: isCurrent) ?? false
                          }, refresh: refresh)
    }

    func cancel() { pending = nil }

    func reset() {
        pending = nil
        deletionTask?.cancel()
    }

    /// Consume consent synchronously before the native presenter can dismiss.
    /// An explicitly cancelled or replaced request can never be replayed.
    @discardableResult
    func beginConfirmation(_ request: Request) -> Task<Void, Never>? {
        guard pending?.id == request.id, !isDeleting, request.isCurrent(), request.isEligible() else { return nil }
        pending = nil
        isDeleting = true
        let task = Task { await perform(request) }
        deletionTask = task
        return task
    }

    func confirm(_ request: Request) async {
        await beginConfirmation(request)?.value
    }

    private func perform(_ request: Request) async {
        defer { isDeleting = false; deletionTask = nil }
        do { try await synchronizeEditors(request.urls) }
        catch { if request.isCurrent() { notify(error.localizedDescription) }; return }
        guard request.isCurrent(), request.isEligible(), !Task.isCancelled,
              request.urls.allSatisfy({ contains($0, in: request.root) && files.fileExists(at: $0) }) else { return }
        guard !request.urls.contains(where: hasUnsavedEdits) else { reportUnsaved(); return }
        if await request.delete(request.urls), request.isCurrent(), request.usesVcs {
            request.urls.filter { !hasUnsavedEdits($0) }.forEach(closeCleanDocuments)
        }
        if request.isCurrent() { await request.refresh() }
    }

    func trash(_ urls: [URL], root: URL, isCurrent: @MainActor () -> Bool) async -> Bool {
        let files = files
        do {
            for url in urls {
                guard isCurrent(), !Task.isCancelled, contains(url, in: root), files.fileExists(at: url) else { return false }
                guard !hasUnsavedEdits(url) else { reportUnsaved(); return false }
                try await Task.detached(priority: .userInitiated) { try files.trashItem(at: url) }.value
                if isCurrent(), !hasUnsavedEdits(url) { closeCleanDocuments(url) }
            }
            return true
        } catch {
            notify(error.localizedDescription)
            return false
        }
    }

    private func contains(_ url: URL, in root: URL) -> Bool {
        let prefix = root.standardizedFileURL.path + "/"
        let resolvedPrefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        // Trash moves the leaf itself, not its symlink target. Its parent must
        // still resolve inside the confirmed root, never through an escape.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.path.hasPrefix(prefix) && parent.hasPrefix(resolvedPrefix)
    }

    private func reportUnsaved() {
        notify(L10n.string("Save or discard unsaved files before deleting this item"))
    }
}
