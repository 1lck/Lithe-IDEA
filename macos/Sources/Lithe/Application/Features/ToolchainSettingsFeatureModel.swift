import Combine
import Darwin
import Foundation
import LitheCoreContracts

/// Owns only settings presentation and read lifecycle, not runtime discovery or launch selection.
@MainActor
final class ToolchainSettingsFeatureModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, ready, failed
    }

    @Published private(set) var snapshot: ToolchainSettingsSnapshot?
    @Published private(set) var state: State = .idle
    @Published private(set) var loadError: (any Error)?
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var selectedDirectoryID = "."
    @Published private(set) var expandedToolIDs: Set<String> = []
    @Published private(set) var loginShell: LoginShellEnvironmentSnapshot?
    @Published private(set) var isRereadingLoginShell = false

    private let loader: (any ToolchainSettingsLoading)?
    let preferences: ToolchainPreferencesFeatureModel
    private let loginShellInspector: (any LoginShellEnvironmentInspecting)?
    private let inputWatcher: (any ToolchainInputWatching)?
    private let reloadDelay: Duration
    private var generation = UUID()
    private var reloadTask: Task<Void, Never>?
    private var inputObservation: AnyObject?

    init(
        loader: (any ToolchainSettingsLoading)? = nil,
        loginShell: (any LoginShellEnvironmentInspecting)? = nil,
        inputWatcher: (any ToolchainInputWatching)? = nil,
        reloadDelay: Duration = .milliseconds(350),
        preferences: (any ToolchainPreferencesStoring)? = nil
    ) {
        self.loader = loader
        self.loginShellInspector = loginShell
        self.inputWatcher = inputWatcher
        self.reloadDelay = reloadDelay
        self.preferences = ToolchainPreferencesFeatureModel(store: preferences)
    }

    var selectedDirectory: ToolchainSettingsSnapshot.Directory? {
        snapshot?.directories.first { $0.id == selectedDirectoryID }
    }

    var tools: [ToolchainSettingsSnapshot.Tool] {
        snapshot?.tools.filter { $0.directoryID == selectedDirectoryID } ?? []
    }

    var providers: [ToolchainSettingsSnapshot.Provider] { snapshot?.providers ?? [] }
    var diagnostics: [String] { snapshot?.diagnostics ?? [] }
    var isLoading: Bool { state == .loading }

    /// Each load revokes older results; callers retain and cancel their structured UI task.
    func load(workspace: URL?) async {
        reloadTask?.cancel()
        reloadTask = nil
        await loadSnapshot(workspace: workspace)
        // A read the app started at launch is still running: show its outcome when it lands.
        if loginShell?.state == .reading, !Task.isCancelled { await rereadLoginShell() }
    }

    /// Reads the login shell again, then the snapshot, whose candidates use the refreshed variables.
    func rereadLoginShell() async {
        guard let loginShellInspector, !isRereadingLoginShell else { return }
        isRereadingLoginShell = true
        let next = await loginShellInspector.reread()
        isRereadingLoginShell = false
        loginShell = next
        guard !Task.isCancelled else { return }
        await loadSnapshot(workspace: workspaceURL)
    }

    /// Any provider input revokes the whole snapshot, so old installations never mix with
    /// new requirements. Nothing runs before the pages first load one.
    func workspaceFilesChanged(_ changes: [WorkspaceFileChange]) {
        guard let root = snapshot?.workspaceURL?.standardizedFileURL.path else { return }
        let patterns = providers.flatMap(\.watchFiles)
        let touched = changes.contains { change in
            let path = change.fileURL.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { return false }
            let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            return patterns.contains { pattern in
                let count = pattern.split(separator: "/").count
                return count <= parts.count && fnmatch(pattern, parts.suffix(count).joined(separator: "/"), FNM_PATHNAME) == 0
            }
        }
        if touched { scheduleReload() }
    }

    /// Bursts of file events collapse into one reload; the latest reload replaces earlier ones.
    private func scheduleReload() {
        guard snapshot != nil else { return }
        reloadTask?.cancel()
        let delay = reloadDelay
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.loadSnapshot(workspace: self.workspaceURL)
        }
    }

    private func observeInputs(of snapshot: ToolchainSettingsSnapshot) {
        inputObservation = inputWatcher?.watch(paths: snapshot.watch) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        }
    }

    private func loadSnapshot(workspace: URL?) async {
        let request = UUID()
        generation = request
        let changedWorkspace = workspaceURL != workspace
        workspaceURL = workspace
        if changedWorkspace {
            preferences.close()
            snapshot = nil
            selectedDirectoryID = "."
            expandedToolIDs = []
        }
        loginShell = loginShellInspector?.inspect()
        loadError = nil
        state = .loading
        do {
            guard let loader else { throw SnapshotError.loaderUnavailable }
            let next = try await loader.load(workspace: workspace)
            guard generation == request else { return }
            try Task.checkCancellation()
            guard next.workspaceURL == workspace else {
                throw SnapshotError.workspaceMismatch
            }
            snapshot = next
            if let address = preferences.address,
               !next.tools.contains(where: { $0.id == address.tool && $0.directoryID == address.directory
                   && (address.consumer == nil || $0.consumers.contains(where: { $0.id == address.consumer })) }) {
                preferences.hide(address)
            }
            observeInputs(of: next)
            if !next.directories.contains(where: { $0.id == selectedDirectoryID }) {
                selectedDirectoryID = next.directories.first?.id ?? "."
            }
            expandedToolIDs.formIntersection(Set(next.tools.map(\.id)))
            state = .ready
        } catch is CancellationError {
            guard generation == request else { return }
            state = .idle
        } catch {
            guard generation == request else { return }
            loadError = error
            state = .failed
        }
    }

    func selectDirectory(_ id: String) {
        guard snapshot?.directories.contains(where: { $0.id == id }) == true else { return }
        selectedDirectoryID = id
    }

    func toggleExpanded(_ toolID: String) {
        guard tools.contains(where: { $0.id == toolID }) else { return }
        if expandedToolIDs.contains(toolID) {
            expandedToolIDs.remove(toolID)
        } else {
            expandedToolIDs.insert(toolID)
        }
    }

    /// Revocation happens before any suspended load can return to this actor.
    func closeAndDrain() async {
        close()
        await preferences.drain()
    }

    func close() {
        preferences.close()
        generation = UUID()
        reloadTask?.cancel()
        reloadTask = nil
        inputObservation = nil
        snapshot = nil
        workspaceURL = nil
        loadError = nil
        state = .idle
        selectedDirectoryID = "."
        expandedToolIDs = []
    }

    private enum SnapshotError: Error {
        case workspaceMismatch, loaderUnavailable
    }
}
