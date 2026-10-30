import Foundation
import LitheCoreContracts

/// Runs coalesced watch deliveries for one subscription, serially.
protocol PluginWorkspaceWatchDelivery: Sendable {
    func schedule(_ work: @escaping @Sendable () -> Void)
}

/// Production delivery: one serial queue per subscription, so a slow plugin
/// callback delays only its own events.
struct MacPluginWorkspaceWatchQueueDelivery: PluginWorkspaceWatchDelivery {
    private let queue = DispatchQueue(label: "app.lithe.plugin-workspace-watch.delivery", qos: .utility)

    func schedule(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

/// Plugin watch subscriptions on top of the existing directory change source.
///
/// Ownership: every subscription belongs to one caller and one root
/// generation. All subscriptions of a generation share one
/// `DirectoryChangeSource` (FSEvents in production), started with the first
/// subscription and stopped with the last. A subscription ends when the caller
/// disposes it, when `releaseResources(of:)` runs for its caller, or when its
/// root generation is closed or superseded.
///
/// Generations: a stream is registered under `(rootID, generation)`. Closing
/// or superseding a generation removes its stream before stopping it, and
/// incoming batches are looked up by that key, so a late callback from an old
/// generation's source finds nothing and can never reach a subscription of a
/// newer generation.
///
/// Coalescing: paths accumulate per subscription while a delivery is queued;
/// one event carries all of them. Above `maximumPendingWatchPaths`, or when
/// the source reports lost events or a replaced root, the pending paths
/// collapse to one `requiresRescan` event.
final class MacPluginWorkspaceWatchHub: @unchecked Sendable {
    private struct StreamKey: Hashable {
        let rootID: String
        let generation: UInt64
    }

    private final class Stream {
        let source: any DirectoryChangeSource
        let rootPrefixes: [String]
        let rootURL: URL
        let visibilityRules: FileVisibilityRules
        var subscriptions: [UUID: Subscription] = [:]

        init(source: any DirectoryChangeSource, rootURL: URL, visibilityRules: FileVisibilityRules) {
            self.source = source
            self.rootURL = rootURL.standardizedFileURL
            self.rootPrefixes = MacPluginWorkspacePaths.rootPrefixes(of: rootURL)
            self.visibilityRules = visibilityRules
        }
    }

    private let budgets: PluginWorkspaceFileBudgets
    private let watcherFactory: any DirectoryWatcherFactory
    private let makeDelivery: @Sendable () -> any PluginWorkspaceWatchDelivery
    private let lock = NSLock()
    private var streams: [StreamKey: Stream] = [:]

    init(
        budgets: PluginWorkspaceFileBudgets,
        watcherFactory: any DirectoryWatcherFactory,
        makeDelivery: @escaping @Sendable () -> any PluginWorkspaceWatchDelivery = { MacPluginWorkspaceWatchQueueDelivery() }
    ) {
        self.budgets = budgets
        self.watcherFactory = watcherFactory
        self.makeDelivery = makeDelivery
    }

    var activeSubscriptionCount: Int {
        lock.withLock { streams.values.reduce(0) { $0 + $1.subscriptions.count } }
    }

    var activeStreamCount: Int {
        lock.withLock { streams.count }
    }

    /// `basePath` must already be validated and NFC-normalized.
    func subscribe(
        basePath: String,
        recursive: Bool,
        root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        onEvent: @escaping @Sendable (PluginWorkspaceWatchEvent) -> Void
    ) throws -> any PluginWorkspaceWatchSubscription {
        let key = StreamKey(rootID: root.id, generation: root.generation)
        let subscription = Subscription(
            hub: self,
            caller: caller,
            rootID: root.id,
            generation: root.generation,
            basePath: basePath,
            recursive: recursive,
            maximumPendingPaths: budgets.maximumPendingWatchPaths,
            delivery: makeDelivery(),
            onEvent: onEvent
        )
        var newSource: (any DirectoryChangeSource)?
        try lock.withLock {
            let all = streams.values.flatMap { $0.subscriptions.values }
            guard all.count < budgets.maximumWatchSubscriptions,
                  all.filter({ $0.caller == caller }).count < budgets.maximumWatchSubscriptionsPerCaller
            else { throw PluginWorkspaceFileError.limitExceeded(.watchSubscriptions) }
            let stream: Stream
            if let existing = streams[key] {
                stream = existing
            } else {
                // `gitContext: nil`: plugin watches cover the workspace tree
                // only; Git metadata stays with the VCS watchers.
                let source = watcherFactory.make(
                    configuration: DirectoryWatchConfiguration(workspaceRoot: root.url, gitContext: nil),
                    visibilityRules: root.visibilityRules,
                    onChange: { [weak self] batch in self?.receive(batch, for: key) }
                )
                stream = Stream(source: source, rootURL: root.url, visibilityRules: root.visibilityRules)
                streams[key] = stream
                newSource = source
            }
            stream.subscriptions[subscription.id] = subscription
        }
        if let newSource {
            // Started outside the lock so a source that reports synchronously
            // cannot deadlock. If every subscription went away meanwhile the
            // stream is no longer registered and is stopped again here.
            newSource.start()
            let stillRegistered = lock.withLock { streams[key]?.source === newSource }
            if !stillRegistered { newSource.stop() }
        }
        return subscription
    }

    func releaseResources(of caller: PluginWorkspaceCaller) {
        removeSubscriptions { $0.caller == caller }
    }

    /// Ends every subscription of `rootID` whose generation is at most
    /// `generation`.
    func closeGenerations(rootID: String, through generation: UInt64) {
        removeSubscriptions { $0.rootID == rootID && $0.generation <= generation }
    }

    fileprivate func remove(_ subscription: Subscription) {
        removeSubscriptions { $0 === subscription }
    }

    private func removeSubscriptions(where shouldRemove: (Subscription) -> Bool) {
        var removed: [Subscription] = []
        var stoppedSources: [any DirectoryChangeSource] = []
        lock.withLock {
            for (key, stream) in streams {
                for subscription in stream.subscriptions.values where shouldRemove(subscription) {
                    stream.subscriptions[subscription.id] = nil
                    removed.append(subscription)
                }
                if stream.subscriptions.isEmpty {
                    streams[key] = nil
                    stoppedSources.append(stream.source)
                }
            }
        }
        // Marked outside the hub lock: marking waits for an in-flight callback
        // of that subscription, which may itself dispose or subscribe.
        removed.forEach { $0.markDisposed() }
        stoppedSources.forEach { $0.stop() }
    }

    private func receive(_ batch: DirectoryChangeBatch, for key: StreamKey) {
        let target: (stream: Stream, subscriptions: [Subscription])? = lock.withLock {
            guard let stream = streams[key] else { return nil }
            return (stream, Array(stream.subscriptions.values))
        }
        guard let target, !target.subscriptions.isEmpty else { return }
        if batch.requiresFullRescan || batch.watchRootsChanged {
            target.subscriptions.forEach { $0.enqueue(paths: [], requiresRescan: true) }
            return
        }
        let stream = target.stream
        let paths = batch.workspacePaths.compactMap { absolutePath -> String? in
            guard let relative = MacPluginWorkspacePaths.relativePath(of: absolutePath, rootPrefixes: stream.rootPrefixes)
            else { return nil }
            guard relative.isEmpty || !stream.visibilityRules.isHiddenPath(
                stream.rootURL.appendingPathComponent(relative),
                relativeTo: stream.rootURL
            ) else { return nil }
            return relative
        }
        guard !paths.isEmpty else { return }
        for subscription in target.subscriptions {
            let matching = paths.filter(subscription.covers)
            if !matching.isEmpty { subscription.enqueue(paths: matching, requiresRescan: false) }
        }
    }

    fileprivate final class Subscription: PluginWorkspaceWatchSubscription, @unchecked Sendable {
        let id = UUID()
        let caller: PluginWorkspaceCaller
        let rootID: String
        let generation: UInt64
        private let basePath: String
        private let recursive: Bool
        private let maximumPendingPaths: Int
        private let delivery: any PluginWorkspaceWatchDelivery
        private let onEvent: @Sendable (PluginWorkspaceWatchEvent) -> Void
        private weak var hub: MacPluginWorkspaceWatchHub?

        private let stateLock = NSLock()
        /// Held while `onEvent` runs; `markDisposed` takes it so that no
        /// callback is running or can start once dispose returns. Recursive
        /// so a callback may dispose its own subscription.
        private let deliveryLock = NSRecursiveLock()
        private var pending: [String] = []
        private var pendingSet: Set<String> = []
        private var rescanPending = false
        private var deliveryScheduled = false
        private var disposed = false
        private var sequence: UInt64 = 0

        init(
            hub: MacPluginWorkspaceWatchHub,
            caller: PluginWorkspaceCaller,
            rootID: String,
            generation: UInt64,
            basePath: String,
            recursive: Bool,
            maximumPendingPaths: Int,
            delivery: any PluginWorkspaceWatchDelivery,
            onEvent: @escaping @Sendable (PluginWorkspaceWatchEvent) -> Void
        ) {
            self.hub = hub
            self.caller = caller
            self.rootID = rootID
            self.generation = generation
            self.basePath = basePath
            self.recursive = recursive
            self.maximumPendingPaths = maximumPendingPaths
            self.delivery = delivery
            self.onEvent = onEvent
        }

        func dispose() {
            if let hub { hub.remove(self) } else { markDisposed() }
        }

        /// Whether a changed relative path belongs to this subscription.
        func covers(_ path: String) -> Bool {
            if path == basePath { return true }
            if recursive {
                return basePath.isEmpty || path.hasPrefix(basePath + "/")
            }
            return MacPluginWorkspacePaths.parent(of: path) == basePath
        }

        func enqueue(paths: [String], requiresRescan: Bool) {
            let shouldSchedule: Bool = stateLock.withLock {
                guard !disposed else { return false }
                if requiresRescan {
                    rescanPending = true
                } else if !rescanPending {
                    for path in paths where pendingSet.insert(path).inserted {
                        pending.append(path)
                    }
                    if pending.count > maximumPendingPaths { rescanPending = true }
                }
                if rescanPending {
                    pending.removeAll()
                    pendingSet.removeAll()
                }
                guard !deliveryScheduled, rescanPending || !pending.isEmpty else { return false }
                deliveryScheduled = true
                return true
            }
            if shouldSchedule {
                delivery.schedule { [self] in flush() }
            }
        }

        func markDisposed() {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            stateLock.withLock {
                disposed = true
                pending.removeAll()
                pendingSet.removeAll()
                rescanPending = false
            }
        }

        private func flush() {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            let event: PluginWorkspaceWatchEvent? = stateLock.withLock {
                deliveryScheduled = false
                guard !disposed, rescanPending || !pending.isEmpty else { return nil }
                sequence += 1
                let event = PluginWorkspaceWatchEvent(
                    subscriptionID: id,
                    rootID: rootID,
                    generation: generation,
                    sequence: sequence,
                    changedPaths: rescanPending ? [] : pending,
                    requiresRescan: rescanPending
                )
                pending.removeAll()
                pendingSet.removeAll()
                rescanPending = false
                return event
            }
            if let event { onEvent(event) }
        }
    }
}

/// Converts host absolute paths into resource paths, for watch and search.
enum MacPluginWorkspacePaths {
    /// The root as given and with links resolved: FSEvents reports real paths
    /// (`/private/var/...`), the search index reports paths under the given
    /// root.
    static func rootPrefixes(of rootURL: URL) -> [String] {
        var prefixes: [String] = []
        for path in [rootURL.path, rootURL.standardizedFileURL.path, rootURL.resolvingSymlinksInPath().standardizedFileURL.path] {
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if trimmed != "/", !prefixes.contains(trimmed) { prefixes.append(trimmed) }
        }
        return prefixes
    }

    /// The validated, NFC-normalized resource path of `absolutePath`, or nil
    /// when it is outside every root prefix or not a valid resource path.
    static func relativePath(of absolutePath: String, rootPrefixes: [String]) -> String? {
        let path = absolutePath.count > 1 && absolutePath.hasSuffix("/") ? String(absolutePath.dropLast()) : absolutePath
        for prefix in rootPrefixes {
            let relative: String
            if path == prefix {
                relative = ""
            } else if path.hasPrefix(prefix + "/") {
                relative = String(path.dropFirst(prefix.count + 1))
            } else {
                continue
            }
            guard let components = try? MacWorkspaceSecurePath.components(of: relative) else { return nil }
            return components.joined(separator: "/")
        }
        return nil
    }

    static func parent(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
