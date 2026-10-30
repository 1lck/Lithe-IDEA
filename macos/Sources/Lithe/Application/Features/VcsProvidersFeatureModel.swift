import Combine
import Foundation
import LitheModuleAPI
import LitheCoreContracts

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// The user's choices for ambiguous directories, per workspace.
protocol VcsRootMappingStoring {
    func mappings(workspaceURL: URL) -> [VcsRootMapping]
    func setMappings(_ mappings: [VcsRootMapping], workspaceURL: URL)
}

/// A working-copy root a plugin provider owns, with the status last read.
struct VcsRootState: Identifiable, Equatable {
    let root: VcsRoot
    let pluginID: String
    /// The provider's display name, such as "Subversion".
    let displayName: String
    /// Built from the workspace URL, so paths below it match the project
    /// tree's even when Core reports the canonical path.
    let url: URL
    let metadataPaths: [String]
    /// Directory markers of the VCS, such as `.svn`; files below them are
    /// metadata, not working files.
    let metadataDirectories: Set<String>
    var negotiation: VcsProviderNegotiation?
    var snapshot: VcsStatusSnapshot?
    var isRefreshing = false
    var failure: String?

    var id: String { root.id }

    /// The root folder's own name for the workspace root and an enclosing
    /// working copy; the relative path for a nested one.
    var title: String {
        root.id.isEmpty || isEnclosing ? url.lastPathComponent : root.id
    }

    /// Whether the root encloses the workspace (`..`, `../..`). Core's rule:
    /// only IDs made entirely of `..` segments, so a folder inside the
    /// workspace may still be named `..repo`.
    var isEnclosing: Bool { Self.isEnclosingRootID(root.id) }

    nonisolated static func isEnclosingRootID(_ id: String) -> Bool {
        !id.isEmpty && id.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 == ".." }
    }

    func supports(_ capability: VcsCapability) -> Bool {
        negotiation?.supports(capability) == true
    }

    /// Whether the change has a base revision worth comparing with. A copy
    /// compares with its source; a new file has nothing to compare.
    func comparesWithBase(_ change: VcsChange) -> Bool {
        supports(.baseContent) && ![.unversioned, .ignored, .added].contains(change.status)
    }
}

/// One file compared with its base revision.
struct VcsFileDiff: Identifiable, Equatable {
    let id = UUID()
    let rootID: String
    let path: String
    let fileURL: URL
    /// Empty for a file with no base; nil when it could not be shown.
    let base: String?
    let current: String?
    let isBinary: Bool
    let isTooLarge: Bool
}

/// Status of project tree rows inside plugin-owned roots, by absolute path.
/// Rows below an unversioned or ignored directory share its status.
struct VcsTreeStatusProjection: Equatable {
    private var statuses: [String: VcsChangeStatus] = [:]
    private var containers: [String: VcsChangeStatus] = [:]

    init(_ statuses: [String: VcsChangeStatus] = [:]) {
        self.statuses = statuses
        containers = statuses.filter { $0.value == .unversioned || $0.value == .ignored }
    }

    var isEmpty: Bool { statuses.isEmpty }

    func status(for url: URL) -> VcsChangeStatus? {
        let path = url.standardizedFileURL.path
        if let status = statuses[path] { return status }
        guard !containers.isEmpty else { return nil }
        var ancestor = Substring(path)
        while let separator = ancestor.lastIndex(of: "/"), separator > ancestor.startIndex {
            ancestor = ancestor[..<separator]
            if let status = containers[String(ancestor)] { return status }
        }
        return nil
    }
}

/// Plugin VCS providers of the open workspace: root detection, status,
/// and the operations of the version control tool window. Rust Core
/// detects roots, decides ownership, and validates every reply; the
/// provider processes run the VCS client. Nothing here names a VCS: what a
/// root offers comes from its provider's negotiated capabilities.
///
/// The built-in Git keeps its own module; its roots only take part in
/// ownership, so a Git repository nested in a working copy is not shown as
/// unversioned files of that working copy.
@MainActor
final class VcsProvidersFeatureModel: ObservableObject {
    static let statusTimeout: Duration = .seconds(120)
    /// Check-in and update may transfer a lot over a slow network.
    static let operationTimeout: Duration = .seconds(30 * 60)
    static let historyPageSize = 50
    /// The host's own requests write the VCS metadata, and the watcher
    /// reports it late; those events must not start another refresh.
    static let metadataQuietPeriod: Duration = .seconds(2)
    static let refreshDelay: Duration = .milliseconds(800)
    /// Larger files are not compared; the diff view builds rows on the main
    /// thread.
    static let diffByteLimit = 2 * 1024 * 1024

    struct RunningOperation: Equatable {
        let rootID: String
        let title: String
    }

    struct Failure: Equatable, Identifiable {
        let id = UUID()
        let rootID: String?
        let message: String
    }

    @Published private(set) var roots: [VcsRootState] = []
    @Published private(set) var ambiguous: [VcsAmbiguousDirectory] = []
    /// Display names of every VCS detection knows, Git included, for the
    /// ambiguous-directory choice.
    @Published private(set) var vcsNames: [String: String] = [:]
    /// Manifests Core refused and VCSs another plugin answers for.
    @Published private(set) var issues: [String] = []
    @Published private(set) var isDetecting = false
    /// The directory budget ran out, so a root may be missing.
    @Published private(set) var isTruncated = false
    /// At most one action that changes a working copy runs at a time.
    @Published private(set) var runningOperation: RunningOperation?
    @Published private(set) var failure: Failure?
    @Published private(set) var treeStatus = VcsTreeStatusProjection()
    /// The diff the window shows in a sheet, from the tool window or the
    /// project tree.
    @Published var presentedDiff: VcsFileDiff?
    private(set) var workspaceURL: URL?
    /// Unsent commit messages per root. They outlive the tool window, so
    /// closing it loses nothing; they are not published, so typing does not
    /// redraw other views.
    var commitMessageDrafts: [String: String] = [:]

    private let planner: any VcsRootPlanning
    private let providers: any VcsProviderRequesting
    private let mappingStore: any VcsRootMappingStoring
    private let sources: @MainActor () -> [VcsProviderPluginSource]
    private let readFile: @MainActor (URL) -> Data?
    private let fileExists: @Sendable (URL) -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let metadataWatcherFactory: (any DirectoryWatcherFactory)?
    /// Watchers of the roots' metadata directories, by path.
    private var metadataWatchers: [String: any DirectoryChangeSource] = [:]

    /// Bumped whenever the workspace changes, so late results are dropped.
    private var generation = 0
    /// Set when the project window's session ends; the feature then stays
    /// empty, whatever late workspace load still asks for.
    private var isShutDown = false
    /// Every detected root, Git included, for ownership.
    private var allRootIDs: [String] = []
    private var markerNames: Set<String> = []
    private var detectionTask: Task<Void, Never>?
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var pendingRefreshes: Set<String> = []
    private var scheduledTask: Task<Void, Never>?
    private var scheduledRoots: Set<String> = []
    private var scheduledDetection = false
    private var activeRequests = 0
    private var metadataQuietUntil: ContinuousClock.Instant?
    private var rootTreeStatuses: [String: [String: VcsChangeStatus]] = [:]
    /// Bumped per root on every status read, so an older ownership answer
    /// cannot replace a newer one.
    private var treeRevisions: [String: Int] = [:]

    init(
        planner: any VcsRootPlanning,
        providers: any VcsProviderRequesting,
        mappingStore: any VcsRootMappingStoring,
        readFile: @escaping @MainActor (URL) -> Data? = { _ in nil },
        fileExists: @escaping @Sendable (URL) -> Bool = { _ in false },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        metadataWatcherFactory: (any DirectoryWatcherFactory)? = nil,
        sources: @escaping @MainActor () -> [VcsProviderPluginSource]
    ) {
        self.planner = planner
        self.providers = providers
        self.mappingStore = mappingStore
        self.readFile = readFile
        self.fileExists = fileExists
        self.sleep = sleep
        self.now = now
        self.metadataWatcherFactory = metadataWatcherFactory
        self.sources = sources
    }

    /// True when an enabled plugin declares a VCS provider, detected or not.
    var hasProviders: Bool { !sources().isEmpty }

    func root(_ id: String) -> VcsRootState? {
        roots.first { $0.id == id }
    }

    // MARK: Workspace

    /// Forgets the previous workspace, stops its providers, and detects the
    /// new one. After `shutdown()` it only clears.
    func reset(workspaceURL: URL?) {
        let workspaceURL = isShutDown ? nil : workspaceURL
        generation += 1
        detectionTask?.cancel(); detectionTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks = [:]
        scheduledTask?.cancel(); scheduledTask = nil
        pendingRefreshes = []; scheduledRoots = []; scheduledDetection = false
        self.workspaceURL = workspaceURL?.standardizedFileURL
        roots = []; ambiguous = []; issues = []; vcsNames = [:]
        allRootIDs = []; markerNames = []
        isTruncated = false; isDetecting = false
        runningOperation = nil; failure = nil
        rootTreeStatuses = [:]; treeStatus = VcsTreeStatusProjection()
        commitMessageDrafts = [:]; presentedDiff = nil
        watchMetadata()
        retainProviders()
        detect()
    }

    /// Ends the feature with its project session: stops every provider and
    /// ignores later requests to load a workspace, such as one from a scan
    /// that finishes while the window closes. A closed session's model is not
    /// reused, so nothing turns it back on.
    func shutdown() {
        isShutDown = true
        reset(workspaceURL: nil)
    }

    /// Detects the roots again with the plugins enabled now. Status already
    /// read is kept for roots that stay.
    func detect() {
        guard let workspaceURL else { return }
        detectionTask?.cancel()
        let sources = sources()
        guard !sources.isEmpty else {
            isDetecting = false
            apply(nil, workspaceURL: workspaceURL, sources: [], mappings: [])
            return
        }
        isDetecting = true
        let mappings = mappingStore.mappings(workspaceURL: workspaceURL)
        let planner = planner
        let generation = generation
        detectionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try planner.detectRoots(
                        workspaceURL: workspaceURL, manifests: sources.map(\.manifest), mappings: mappings
                    )
                }
            }.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.detectionTask = nil
            self.isDetecting = false
            switch result {
            case .success(let detection):
                self.apply(detection, workspaceURL: workspaceURL, sources: sources, mappings: mappings)
            case .failure(let error):
                self.apply(nil, workspaceURL: workspaceURL, sources: sources, mappings: [])
                self.issues = [Self.message(for: error)]
            }
        }
    }

    /// Stops what a now disabled plugin started and detects again.
    func pluginsChanged() {
        retainProviders()
        detect()
    }

    /// Chooses the VCS of an ambiguous directory and detects again.
    func map(_ directoryID: String, to vcs: String) {
        guard let workspaceURL else { return }
        var mappings = mappingStore.mappings(workspaceURL: workspaceURL).filter { $0.id != directoryID }
        mappings.append(VcsRootMapping(id: directoryID, vcs: vcs))
        mappingStore.setMappings(mappings, workspaceURL: workspaceURL)
        detect()
    }

    private func apply(
        _ detection: VcsDetection?,
        workspaceURL: URL,
        sources: [VcsProviderPluginSource],
        mappings: [VcsRootMapping]
    ) {
        let plugins = Dictionary(
            (detection?.providers ?? []).compactMap { provider -> (String, VcsProviderDescriptor)? in
                guard provider.origin.kind == "plugin", provider.origin.pluginID != nil else { return nil }
                return (provider.vcs, provider)
            },
            uniquingKeysWith: { first, _ in first }
        )
        vcsNames = Dictionary(
            (detection?.providers ?? []).map { ($0.vcs, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        markerNames = Set(plugins.values.flatMap { $0.markers.map(\.name) })
        let previous = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        roots = (detection?.roots ?? []).compactMap { root in
            guard let provider = plugins[root.vcs], let pluginID = provider.origin.pluginID else { return nil }
            var state = VcsRootState(
                root: root, pluginID: pluginID, displayName: provider.displayName,
                url: Self.rootURL(id: root.id, workspaceURL: workspaceURL),
                metadataPaths: provider.metadataPaths ?? [],
                metadataDirectories: Set(provider.markers.filter { $0.type == "directory" }.map(\.name))
            )
            if let old = previous[root.id], old.root.vcs == root.vcs, old.pluginID == pluginID {
                state.negotiation = old.negotiation
                state.snapshot = old.snapshot
                state.isRefreshing = old.isRefreshing
                state.failure = old.failure
            }
            return state
        }
        allRootIDs = detection?.roots.map(\.id) ?? []
        ambiguous = detection?.ambiguous ?? []
        isTruncated = detection?.truncated ?? false
        issues = (detection?.rejected ?? []).map { rejected in
            let pluginID = rejected.index < sources.count ? sources[rejected.index].pluginID : "?"
            return "\(pluginID): \(rejected.error.message)"
        } + (detection?.conflicts ?? []).map { conflict in
            String(
                format: L10n.string("%1$@ does not provide %2$@ because %3$@ already does."),
                conflict.pluginID, vcsNames[conflict.vcs] ?? conflict.vcs, conflict.by
            )
        }
        let kept = Set(roots.map(\.id))
        rootTreeStatuses = rootTreeStatuses.filter { kept.contains($0.key) }
        publishTreeStatus()
        if let unused = detection?.unusedMappings, !unused.isEmpty {
            mappingStore.setMappings(mappings.filter { !unused.contains($0) }, workspaceURL: workspaceURL)
        }
        watchMetadata()
        retainProviders()
        roots.forEach { refresh($0.id) }
    }

    /// Stops processes of other workspaces, disabled or replaced plugins,
    /// and VCSs with no root left.
    private func retainProviders() {
        let workspaceURL = workspaceURL
        let packages = Set(sources().map { [$0.pluginID, $0.packageURL.standardizedFileURL.path] })
        let used = Set(roots.map { [$0.pluginID, $0.root.vcs] })
        providers.retainProviders { target in
            target.workspaceURL == workspaceURL
                && packages.contains([target.pluginID, target.packageURL.standardizedFileURL.path])
                && used.contains([target.pluginID, target.vcs])
        }
    }

    // MARK: File changes

    /// Watches the metadata directory of every root, such as `.svn` or
    /// `../.svn`. The workspace watcher hides VCS metadata as the project
    /// tree does and never sees a working copy that encloses the workspace,
    /// so a commit or update from a terminal would otherwise go unnoticed.
    /// Only the directory holding a declared metadata path is watched.
    private func watchMetadata() {
        guard let metadataWatcherFactory else { return }
        var directories: [String: URL] = [:]
        for root in roots {
            for path in root.metadataPaths {
                guard let first = path.split(separator: "/").first.map(String.init),
                      root.metadataDirectories.contains(first) else { continue }
                let url = root.url.appendingPathComponent(first, isDirectory: true).standardizedFileURL
                directories[url.path] = url
            }
        }
        for (path, watcher) in metadataWatchers where directories[path] == nil {
            watcher.stop()
            metadataWatchers[path] = nil
        }
        for (path, url) in directories where metadataWatchers[path] == nil {
            let watcher = metadataWatcherFactory.make(
                configuration: DirectoryWatchConfiguration(workspaceRoot: url, gitContext: nil),
                visibilityRules: .default
            ) { [weak self] batch in
                Task { @MainActor [weak self] in self?.metadataChanged(batch, in: url) }
            }
            metadataWatchers[path] = watcher
            watcher.start()
        }
    }

    /// A metadata directory that lost track of its events, or went away,
    /// counts as the marker changing, so the roots are detected again.
    private func metadataChanged(_ batch: DirectoryChangeBatch, in directory: URL) {
        guard metadataWatchers[directory.path] != nil else { return }
        filesChanged(
            batch.requiresFullRescan ? [directory] : batch.workspacePaths.map { URL(fileURLWithPath: $0) }
        )
    }

    /// Workspace changes: the roots whose working files changed are read
    /// again. The workspace watcher hides VCS markers, so a new working copy
    /// shows only as created entries next to its marker.
    func workspaceFilesChanged(_ changes: [WorkspaceFileChange]) {
        filesChanged(changes.map(\.fileURL))
        detectNewRoots(near: changes.filter { $0.kind == .created }.map(\.fileURL))
    }

    /// Refreshes the roots whose files changed, shortly after the last
    /// change. Metadata changes count only for the provider's declared
    /// metadata paths, and not while the host's own requests write them.
    /// A marker directory going away detects again.
    private func filesChanged(_ urls: [URL]) {
        guard workspaceURL != nil, hasProviders else { return }
        let quiet = activeRequests > 0 || metadataQuietUntil.map { now() < $0 } == true
        let byDepth = roots.sorted { $0.url.path.count > $1.url.path.count }
        var affected: Set<String> = []
        var redetect = false
        for url in urls {
            let path = url.standardizedFileURL.path
            if markerNames.contains(url.lastPathComponent), !quiet { redetect = true }
            guard let root = byDepth.first(where: { path.hasPrefix($0.url.path + "/") }) else { continue }
            let relative = String(path.dropFirst(root.url.path.count + 1))
            let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relative
            if root.metadataDirectories.contains(first) {
                guard !quiet, root.metadataPaths.contains(where: {
                    relative == $0 || relative.hasPrefix($0 + "/")
                }) else { continue }
            }
            affected.insert(root.id)
        }
        schedule(roots: affected, detect: redetect)
    }

    /// Detects again when a created entry, or the directory holding it, has
    /// a marker but is no known root or ambiguous directory, as after a
    /// checkout or an update that fetched an external. The markers are
    /// looked up off the main thread.
    private func detectNewRoots(near created: [URL]) {
        guard let workspaceURL, !created.isEmpty, !markerNames.isEmpty else { return }
        let known = Set((allRootIDs + ambiguous.map(\.id)).map { Self.rootURL(id: $0, workspaceURL: workspaceURL).path })
        let workspacePath = workspaceURL.path
        var directories: Set<String> = []
        for url in created {
            let url = url.standardizedFileURL
            for path in [url.path, url.deletingLastPathComponent().path]
            where (path == workspacePath || path.hasPrefix(workspacePath + "/")) && !known.contains(path) {
                directories.insert(path)
            }
        }
        guard !directories.isEmpty else { return }
        let markers = markerNames
        let fileExists = fileExists
        let generation = generation
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                directories.contains { directory in
                    markers.contains { fileExists(URL(fileURLWithPath: directory).appendingPathComponent($0)) }
                }
            }.value
            guard found, let self, self.generation == generation else { return }
            self.schedule(roots: [], detect: true)
        }
    }

    /// Refreshes `roots`, or detects again, shortly after the last change.
    private func schedule(roots affected: Set<String>, detect redetect: Bool) {
        guard redetect || !affected.isEmpty else { return }
        scheduledRoots.formUnion(affected)
        scheduledDetection = scheduledDetection || redetect
        scheduledTask?.cancel()
        let sleep = sleep
        let generation = generation
        scheduledTask = Task { [weak self] in
            do { try await sleep(Self.refreshDelay) } catch { return }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            let roots = self.scheduledRoots
            let detects = self.scheduledDetection
            self.scheduledRoots = []; self.scheduledDetection = false; self.scheduledTask = nil
            // Detection refreshes every root it keeps.
            if detects { self.detect() } else { roots.forEach(self.refresh) }
        }
    }

    // MARK: Status

    func refreshAll() {
        roots.forEach { refresh($0.id) }
    }

    /// Reads the root's status. A refresh asked for while one runs, or
    /// while an action changes the root, runs once that ends.
    func refresh(_ rootID: String) {
        guard let index = index(of: rootID) else { return }
        guard refreshTasks[rootID] == nil, runningOperation?.rootID != rootID else {
            pendingRefreshes.insert(rootID)
            return
        }
        roots[index].isRefreshing = true
        let generation = generation
        refreshTasks[rootID] = Task { [weak self] in
            guard let self else { return }
            var snapshot: VcsStatusSnapshot?
            var failure: Error?
            do {
                snapshot = try await self.request(
                    .status(includeIgnored: false), rootID: rootID, timeout: Self.statusTimeout,
                    as: VcsStatusSnapshot.self
                )
            } catch {
                failure = error
            }
            guard self.generation == generation else { return }
            self.refreshTasks[rootID] = nil
            if let index = self.index(of: rootID) {
                self.roots[index].isRefreshing = false
                if let snapshot {
                    self.roots[index].snapshot = snapshot
                    self.roots[index].failure = nil
                    self.updateTreeStatus(rootID: rootID, snapshot: snapshot)
                } else if let failure, !(failure is CancellationError) {
                    self.roots[index].failure = Self.message(for: failure)
                }
            }
            if self.pendingRefreshes.remove(rootID) != nil { self.refresh(rootID) }
        }
    }

    /// Projects the root's changes onto the project tree. Changes that
    /// belong to a nested root, such as a Git repository inside a working
    /// copy, or that lie outside the workspace, are left out.
    private func updateTreeStatus(rootID: String, snapshot: VcsStatusSnapshot) {
        guard let workspaceURL else { return }
        var paths: [String] = []
        var statuses: [VcsChangeStatus] = []
        for change in snapshot.changes where change.status != .ignored {
            guard let path = Self.workspacePath(change.path, rootID: rootID, workspaceURL: workspaceURL),
                  !path.isEmpty else { continue }
            paths.append(path)
            statuses.append(change.hasTreeConflict ? .conflicted : change.status)
        }
        let revision = (treeRevisions[rootID] ?? 0) + 1
        treeRevisions[rootID] = revision
        let planner = planner
        let rootIDs = allRootIDs
        let ambiguousIDs = ambiguous.map(\.id)
        let generation = generation
        Task { [weak self] in
            let owners = await Task.detached(priority: .utility) {
                try? planner.owners(roots: rootIDs, ambiguous: ambiguousIDs, paths: paths)
            }.value
            guard let self, self.generation == generation, self.treeRevisions[rootID] == revision,
                  self.index(of: rootID) != nil else { return }
            var entries: [String: VcsChangeStatus] = [:]
            for (index, path) in paths.enumerated() where owners.map({ $0[index] == rootID }) ?? true {
                entries[workspaceURL.appendingPathComponent(path).standardizedFileURL.path] = statuses[index]
            }
            self.rootTreeStatuses[rootID] = entries
            self.publishTreeStatus()
        }
    }

    private func publishTreeStatus() {
        let merged = rootTreeStatuses.values.reduce(into: [String: VcsChangeStatus]()) { result, entries in
            result.merge(entries) { current, _ in current }
        }
        let projection = VcsTreeStatusProjection(merged)
        if projection != treeStatus { treeStatus = projection }
    }

    // MARK: Actions

    /// Commits `paths`, root-relative. The provider adds selected
    /// unversioned files and removes missing ones as part of the check-in.
    func checkin(_ paths: [String], message: String, in rootID: String) async -> VcsCheckinResult? {
        await perform(.checkin(paths: paths, message: message), in: rootID,
                      title: L10n.string("Committing…"), as: VcsCheckinResult.self)
    }

    func rollback(_ paths: [String], in rootID: String) async -> Bool {
        await perform(.rollback(paths: paths), in: rootID,
                      title: L10n.string("Rolling back…"), as: VcsEmptyResult.self) != nil
    }

    func update(_ rootID: String) async -> VcsUpdateResult? {
        await perform(.update(revision: nil), in: rootID,
                      title: L10n.string("Updating…"), as: VcsUpdateResult.self)
    }

    func resolve(_ paths: [String], in rootID: String) async -> Bool {
        await perform(.resolve(paths: paths), in: rootID,
                      title: L10n.string("Marking as resolved…"), as: VcsEmptyResult.self) != nil
    }

    func cleanup(_ rootID: String) async -> Bool {
        await perform(.cleanup, in: rootID,
                      title: L10n.string("Cleaning up…"), as: VcsEmptyResult.self) != nil
    }

    func canAdd(_ changes: [VcsChange], in rootID: String) -> Bool {
        canChangeFiles(changes, in: rootID)
            && changes.allSatisfy { $0.status == .unversioned }
    }

    func canDelete(_ changes: [VcsChange], in rootID: String) -> Bool {
        canChangeFiles(changes, in: rootID)
            && changes.allSatisfy { ![.unversioned, .ignored, .deleted, .missing].contains($0.status) }
    }

    func canTrash(_ changes: [VcsChange], in rootID: String) -> Bool {
        canChangeFiles(changes, in: rootID, requiresProvider: false)
            && changes.allSatisfy { $0.status == .unversioned }
    }

    private func canChangeFiles(_ changes: [VcsChange], in rootID: String, requiresProvider: Bool = true) -> Bool {
        guard runningOperation == nil, !isDetecting, let root = root(rootID), !root.isRefreshing,
              !isTruncated, (!requiresProvider || root.supports(.fileOperations)),
              let workspaceURL, !changes.isEmpty else { return false }
        return changes.allSatisfy {
            root.snapshot?.changes.contains($0) == true
                && Self.workspacePath($0.path, rootID: rootID, workspaceURL: workspaceURL) != nil
                && !containsOtherRoot($0, in: root)
        }
    }

    /// A recursive add/delete must not cross a nested working copy, even when
    /// the selected directory itself belongs to the enclosing provider.
    private func containsOtherRoot(_ change: VcsChange, in root: VcsRootState) -> Bool {
        guard let workspaceURL else { return true }
        let target = root.url.appendingPathComponent(change.path).standardizedFileURL.path
        return (allRootIDs + ambiguous.map(\.id)).filter { $0 != root.id }.contains {
            let path = Self.rootURL(id: $0, workspaceURL: workspaceURL).path
            return path == target || path.hasPrefix(target + "/")
        }
    }

    func trash(_ changes: [VcsChange], in rootID: String,
               action: @MainActor () async -> Bool) async -> Bool {
        guard canTrash(changes, in: rootID), await owns(changes, in: rootID), canTrash(changes, in: rootID) else { return false }
        let generation = generation
        runningOperation = RunningOperation(rootID: rootID, title: L10n.string("Deleting…"))
        defer {
            if self.generation == generation { runningOperation = nil; refresh(rootID) }
        }
        return await action()
    }

    func add(_ changes: [VcsChange], in rootID: String) async -> Bool {
        guard canAdd(changes, in: rootID), await owns(changes, in: rootID), canAdd(changes, in: rootID) else { return false }
        return await perform(.add(paths: Array(Set(changes.map(\.path))).sorted()), in: rootID,
                             title: L10n.string("Adding to VCS…"), as: VcsEmptyResult.self) != nil
    }

    /// No filesystem fallback: a provider refusal must not turn into an
    /// untracked disk deletion (notably for working copies such as SVN).
    func delete(_ changes: [VcsChange], in rootID: String) async -> Bool {
        guard canDelete(changes, in: rootID), await owns(changes, in: rootID), canDelete(changes, in: rootID) else { return false }
        return await perform(.delete(paths: Array(Set(changes.map(\.path))).sorted()), in: rootID,
                             title: L10n.string("Deleting…"), as: VcsEmptyResult.self) != nil
    }

    private func owns(_ changes: [VcsChange], in rootID: String) async -> Bool {
        guard let workspaceURL else { return false }
        let paths = changes.compactMap { Self.workspacePath($0.path, rootID: rootID, workspaceURL: workspaceURL) }
        guard paths.count == changes.count else { return false }
        let planner = planner, roots = allRootIDs, ambiguous = ambiguous.map(\.id), generation = generation
        do {
            let owners = try await Task.detached(priority: .userInitiated) {
                try planner.owners(roots: roots, ambiguous: ambiguous, paths: paths)
            }.value
            guard self.generation == generation, !Task.isCancelled,
                  allRootIDs == roots, self.ambiguous.map(\.id) == ambiguous else { return false }
            guard owners.count == paths.count, owners.allSatisfy({ $0 == rootID }) else {
                report(L10n.string("Some selected files belong to another version control root. Refresh and select them again."), rootID: rootID)
                return false
            }
            return true
        } catch {
            if self.generation == generation { report(Self.message(for: error), rootID: rootID) }
            return false
        }
    }

    func baseContent(_ path: String, in rootID: String) async throws -> VcsBaseContent {
        try await request(.baseContent(path: path), rootID: rootID, timeout: Self.statusTimeout, as: VcsBaseContent.self)
    }

    func history(in rootID: String, cursor: String?) async throws -> VcsHistoryPage {
        try await request(
            .history(cursor: cursor, limit: Self.historyPageSize), rootID: rootID,
            timeout: Self.operationTimeout, as: VcsHistoryPage.self
        )
    }

    func fileHistory(_ path: String, in rootID: String, cursor: String?) async throws -> VcsHistoryPage {
        try await request(
            .fileHistory(path: path, cursor: cursor, limit: Self.historyPageSize), rootID: rootID,
            timeout: Self.operationTimeout, as: VcsHistoryPage.self
        )
    }

    /// The change's base revision next to the file on disk. A file with no
    /// base compares with nothing, and so does a deleted one.
    func diff(for change: VcsChange, in rootID: String) async throws -> VcsFileDiff {
        guard let root = root(rootID) else { throw CancellationError() }
        let generation = generation
        let fileURL = root.url.appendingPathComponent(change.path).standardizedFileURL
        var current: String? = ""
        var isBinary = false
        var isTooLarge = false
        if ![.deleted, .missing].contains(change.status) {
            let data = readFile(fileURL)
            isTooLarge = (data?.count ?? 0) > Self.diffByteLimit
            current = isTooLarge ? nil : data.flatMap { String(data: $0, encoding: .utf8) }
            isBinary = data != nil && !isTooLarge && current == nil
        }
        var base: String? = ""
        if ![.added, .unversioned, .ignored].contains(change.status), !isBinary, !isTooLarge {
            let content = try await baseContent(change.path, in: rootID)
            isBinary = content.binary
            isTooLarge = (content.content?.utf8.count ?? 0) > Self.diffByteLimit
            base = isBinary || isTooLarge ? nil : content.content ?? ""
        }
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        return VcsFileDiff(
            rootID: rootID, path: change.path, fileURL: fileURL,
            base: base, current: isBinary || isTooLarge ? nil : current,
            isBinary: isBinary, isTooLarge: isTooLarge
        )
    }

    /// Loads the change's diff and presents it; a failure is reported.
    func showDiff(_ change: VcsChange, in rootID: String) {
        let generation = generation
        Task {
            do {
                let diff = try await diff(for: change, in: rootID)
                if self.generation == generation { presentedDiff = diff }
            } catch is CancellationError {
            } catch {
                if self.generation == generation { report(Self.message(for: error), rootID: rootID) }
            }
        }
    }

    /// The change the last status of `url`'s root lists for it, for the
    /// project tree.
    func change(at url: URL) -> (root: VcsRootState, change: VcsChange)? {
        guard let (root, path) = rootPath(of: url), !path.isEmpty,
              let change = root.snapshot?.changes.first(where: { $0.path == path }) else { return nil }
        return (root, change)
    }

    /// Moves a project item through the provider of the root that holds
    /// both locations, so the VCS records the move. Returns false when no
    /// such root tracks the item, or the provider refused; the caller then
    /// moves it on disk, and a refusal is reported.
    func move(from source: URL, to destination: URL) async -> Bool {
        guard runningOperation == nil, let workspaceURL,
              let (root, from) = rootPath(of: source), let (destinationRoot, to) = rootPath(of: destination),
              root.id == destinationRoot.id, root.supports(.fileOperations), !from.isEmpty, !to.isEmpty,
              !isUnversioned(source, in: root), !isUnversioned(destination.deletingLastPathComponent(), in: root),
              let sourcePath = Self.workspaceRelativePath(source, workspaceURL: workspaceURL),
              let destinationPath = Self.workspaceRelativePath(destination, workspaceURL: workspaceURL)
        else { return false }
        // Both ends must belong to the root by Core's rule: a nested root of
        // another VCS, such as a Git repository, or an ambiguous directory
        // with no VCS chosen takes its paths away from the working copy.
        let planner = planner
        let rootIDs = allRootIDs
        let ambiguousIDs = ambiguous.map(\.id)
        let generation = generation
        let owners = await Task.detached(priority: .userInitiated) {
            try? planner.owners(roots: rootIDs, ambiguous: ambiguousIDs, paths: [sourcePath, destinationPath])
        }.value
        // An action that started meanwhile leaves the move to the disk, as
        // one running before would, instead of reporting it as refused.
        guard self.generation == generation, runningOperation == nil,
              let owners, owners == [root.id, root.id] else { return false }
        return await perform(.move(from: from, to: to), in: root.id,
                             title: L10n.string("Moving…"), as: VcsEmptyResult.self) != nil
    }

    func dismissFailure() {
        failure = nil
    }

    func report(_ message: String, rootID: String?) {
        failure = Failure(rootID: rootID, message: message)
    }

    /// Runs an action that changes the working copy, then reads its status
    /// again. A failure is reported through `failure`.
    private func perform<Value: Decodable & Sendable>(
        _ operation: VcsOperation,
        in rootID: String,
        title: String,
        as type: Value.Type
    ) async -> Value? {
        guard runningOperation == nil else {
            report(L10n.string("Wait for the running version control action to finish."), rootID: rootID)
            return nil
        }
        runningOperation = RunningOperation(rootID: rootID, title: title)
        failure = nil
        let generation = generation
        defer {
            if self.generation == generation {
                runningOperation = nil
                refresh(rootID)
            }
        }
        do {
            return try await request(operation, rootID: rootID, timeout: Self.operationTimeout, as: type)
        } catch {
            if self.generation == generation, !(error is CancellationError) {
                report(Self.message(for: error), rootID: rootID)
            }
            return nil
        }
    }

    /// Sends one operation to the root's provider and has Core validate the
    /// reply.
    private func request<Value: Decodable & Sendable>(
        _ operation: VcsOperation,
        rootID: String,
        timeout: Duration,
        as type: Value.Type
    ) async throws -> Value {
        guard let state = root(rootID), let target = target(for: state) else {
            throw VcsProviderFailure(
                code: "vcs.provider.unavailable",
                message: L10n.string("This working copy is no longer available. Refresh and try again.")
            )
        }
        let generation = generation
        activeRequests += 1
        defer {
            activeRequests -= 1
            metadataQuietUntil = now() + Self.metadataQuietPeriod
        }
        let reply = try await providers.send(operation, root: state.root.path, to: target, timeout: timeout)
        guard self.generation == generation else { throw CancellationError() }
        if let index = index(of: rootID), roots[index].negotiation != reply.negotiation {
            roots[index].negotiation = reply.negotiation
        }
        let planner = planner
        let value = try await Task.detached(priority: .userInitiated) {
            try planner.decodeReply(
                operation, capabilities: reply.negotiation.capabilities, reply: reply.value, as: Value.self
            )
        }.value
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    private func target(for state: VcsRootState) -> VcsProviderTarget? {
        guard let workspaceURL,
              let source = sources().first(where: { $0.pluginID == state.pluginID }) else { return nil }
        return VcsProviderTarget(
            pluginID: source.pluginID, vcs: state.root.vcs, manifest: source.manifest,
            packageURL: source.packageURL, workspaceURL: workspaceURL
        )
    }

    private func index(of rootID: String) -> Int? {
        roots.firstIndex { $0.id == rootID }
    }

    // MARK: Paths

    /// The deepest plugin root holding `url`, with the root-relative path.
    func rootPath(of url: URL) -> (VcsRootState, String)? {
        let path = url.standardizedFileURL.path
        let byDepth = roots.sorted { $0.url.path.count > $1.url.path.count }
        for root in byDepth {
            if path == root.url.path { return (root, "") }
            if path.hasPrefix(root.url.path + "/") {
                return (root, String(path.dropFirst(root.url.path.count + 1)))
            }
        }
        return nil
    }

    private static func workspaceRelativePath(_ url: URL, workspaceURL: URL) -> String? {
        let path = url.standardizedFileURL.path
        let base = workspaceURL.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }

    private func isUnversioned(_ url: URL, in root: VcsRootState) -> Bool {
        guard let status = treeStatus.status(for: url) else { return false }
        return status == .unversioned || status == .ignored
    }

    static func rootURL(id: String, workspaceURL: URL) -> URL {
        id.isEmpty ? workspaceURL.standardizedFileURL : workspaceURL.appendingPathComponent(id).standardizedFileURL
    }

    /// The workspace-relative path of a root-relative one; nil outside the
    /// workspace, which only an enclosing working copy can report.
    nonisolated static func workspacePath(_ path: String, rootID: String, workspaceURL: URL) -> String? {
        guard VcsRootState.isEnclosingRootID(rootID) else { return rootID.isEmpty ? path : rootID + "/" + path }
        let levels = rootID.split(separator: "/").count
        let inside = workspaceURL.standardizedFileURL.pathComponents.suffix(levels).joined(separator: "/")
        if path == inside { return "" }
        return path.hasPrefix(inside + "/") ? String(path.dropFirst(inside.count + 1)) : nil
    }

    // MARK: Messages

    /// The provider's message, after a hint for the failures the contract
    /// names.
    static func message(for error: Error) -> String {
        guard let failure = error as? VcsProviderFailure else { return error.localizedDescription }
        let hint: String? = switch failure.code {
        case "vcs.authentication.failed":
            L10n.string("Authentication failed. Lithe cannot ask for credentials yet: sign in once with the command-line client so it stores them, then try again.")
        case "vcs.outOfDate":
            L10n.string("The working copy is out of date. Update it, then commit again.")
        case "vcs.conflict":
            L10n.string("The action stopped on conflicted files. Resolve them, then try again.")
        case "vcs.workingCopy.locked":
            L10n.string("The working copy is locked by an interrupted action. Run Cleanup, then try again.")
        case "vcs.workingCopy.unsupported":
            L10n.string("This working copy format is not supported. Upgrade it with the command-line client.")
        case "vcs.tool.unavailable":
            L10n.string("The version control client could not be run. Check that it is installed.")
        default:
            nil
        }
        guard let hint else { return failure.message }
        return failure.message.isEmpty ? hint : hint + "\n" + failure.message
    }
}
