import Foundation
import LitheCoreContracts

/// Owns host subscriptions independently of the UI executor. A generation
/// prevents late events from a cancelled or replaced subscription refreshing
/// the next workspace.
final class RemoteDirectoryObservation: DirectoryChangeSource, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let configuration: DirectoryWatchConfiguration
    private let visibilityRules: FileVisibilityRules
    private let binding: RemoteWorkspaceBinding
    private let registry: RemoteWorkspaceRegistry
    private let transport: any RemoteWorkspaceTransport
    private let onChange: @Sendable (DirectoryChangeBatch) -> Void
    private var tasks: [Task<Void, Never>] = []
    private var generation = UUID()

    init(
        configuration: DirectoryWatchConfiguration, visibilityRules: FileVisibilityRules,
        binding: RemoteWorkspaceBinding, registry: RemoteWorkspaceRegistry,
        transport: any RemoteWorkspaceTransport,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) {
        self.configuration = configuration
        self.visibilityRules = visibilityRules
        self.binding = binding
        self.registry = registry
        self.transport = transport
        self.onChange = onChange
    }

    func start() {
        lock.withLock {
            stop()
            let current = generation
            for root in configuration.physicalRoots {
                // Git common directories may live outside the workspace. The
                // Core Git engine already returns those as absolute host paths.
                let remoteRoot = registry.resolve(root)?.remotePath ?? root.path
                let transport = transport
                let session = binding.sessionID
                tasks.append(Task { [weak self] in
                    do {
                        try await transport.watch(root: remoteRoot, session: session) { [weak self] event in
                            self?.receive(event, generation: current)
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        NSLog("Remote directory watch ended: %@", String(describing: type(of: error)))
                        self?.receive(.invalidated(rootRemoved: false), generation: current)
                    }
                })
            }
        }
    }

    func stop() {
        lock.withLock {
            generation = UUID()
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    private func receive(_ event: RemoteWatchEvent, generation: UUID) {
        lock.withLock {
            guard self.generation == generation else { return }
            var batch = DirectoryChangeBatch()
            switch event {
            case .started:
                batch.requiresFullRescan = true
                batch.gitStateMayHaveChanged = true
            case .invalidated(let rootRemoved):
                batch.requiresFullRescan = true
                batch.gitStateMayHaveChanged = true
                batch.watchRootsChanged = rootRemoved
            case .changed(let paths, let overflow):
                batch.requiresFullRescan = overflow
                batch.gitStateMayHaveChanged = overflow
                var workspacePaths = Set<String>()
                for path in paths {
                    let hostRoot = binding.remoteRoot.hasSuffix("/") ? binding.remoteRoot : binding.remoteRoot + "/"
                    let url: URL
                    if path == binding.remoteRoot { url = binding.root }
                    else if path.hasPrefix(hostRoot) {
                        url = binding.root.appendingPathComponent(String(path.dropFirst(hostRoot.count))).standardizedFileURL
                    } else { url = URL(fileURLWithPath: path).standardizedFileURL }
                    if configuration.revalidatesIgnoredDirectory(url, isStructuralChange: true) {
                        batch.requiresFullRescan = true
                        batch.gitStateMayHaveChanged = true
                    }
                    if configuration.isIgnored(url) { continue }
                    if configuration.isGitContextPointer(url) {
                        batch.gitStateMayHaveChanged = true
                        batch.watchRootsChanged = true
                    } else if configuration.containsGitMetadataPath(url) {
                        batch.gitStateMayHaveChanged = true
                    } else if configuration.containsWorkspacePath(url) {
                        batch.gitStateMayHaveChanged = true
                        if !visibilityRules.isHiddenPath(url, relativeTo: configuration.workspaceRoot)
                            || visibilityRules.isWatchedDespiteHiding(url, relativeTo: configuration.workspaceRoot) {
                            workspacePaths.insert(url.path)
                        }
                    } else if configuration.containsRepositoryPath(url) {
                        batch.gitStateMayHaveChanged = true
                    }
                }
                batch.workspacePaths = workspacePaths.sorted()
            }
            if !batch.isEmpty { onChange(batch) }
        }
    }

    deinit { stop() }
}

/// The editor owns both local and remote observers through its existing port.
final class RemoteDocumentObservations: DocumentFileObservation, @unchecked Sendable {
    private let local: any DocumentFileObservation
    private let remote: [RemoteDirectoryObservation]

    init(local: any DocumentFileObservation, remote: [RemoteDirectoryObservation]) {
        self.local = local
        self.remote = remote
    }

    func cancel() {
        local.cancel()
        remote.forEach { $0.stop() }
    }

    deinit { cancel() }
}
