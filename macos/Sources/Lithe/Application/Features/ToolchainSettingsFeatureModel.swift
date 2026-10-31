import Combine
import Foundation

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
    private let loginShellInspector: (any LoginShellEnvironmentInspecting)?
    private var generation = UUID()

    init(loader: (any ToolchainSettingsLoading)? = nil, loginShell: (any LoginShellEnvironmentInspecting)? = nil) {
        self.loader = loader
        self.loginShellInspector = loginShell
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

    private func loadSnapshot(workspace: URL?) async {
        let request = UUID()
        generation = request
        let changedWorkspace = workspaceURL != workspace
        workspaceURL = workspace
        if changedWorkspace {
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
    func close() {
        generation = UUID()
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
