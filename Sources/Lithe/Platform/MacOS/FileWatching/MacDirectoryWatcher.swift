import CoreServices
import Foundation

final class MacDirectoryWatcher: DirectoryChangeSource, @unchecked Sendable {
    private final class CallbackContext {
        weak var watcher: MacDirectoryWatcher?

        init(watcher: MacDirectoryWatcher) {
            self.watcher = watcher
        }
    }

    private let configuration: DirectoryWatchConfiguration
    private let visibilityRules: FileVisibilityRules
    private let queue = DispatchQueue(label: "app.lithe.file-events", qos: .utility)
    private let onChange: @Sendable (DirectoryChangeBatch) -> Void
    private var stream: FSEventStreamRef?

    init(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules = .default,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) {
        self.configuration = configuration
        self.visibilityRules = visibilityRules
        self.onChange = onChange
    }

    func start() {
        stop()
        let callbackContext = CallbackContext(watcher: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info, eventCount > 0 else { return }
            let callbackContext = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = callbackContext.watcher else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let visiblePaths = paths.filter { path in
                let url = URL(fileURLWithPath: path)
                return !MacFileWriteEventSuppression.consume(url) &&
                    !watcher.visibilityRules.isHiddenPath(
                    url,
                    relativeTo: watcher.root
                )
            }
            guard !visiblePaths.isEmpty else { return }
            watcher.onChange(visiblePaths)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            configuration.physicalRoots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func classify(
        paths: [String],
        eventFlags: [FSEventStreamEventFlags]
    ) -> DirectoryChangeBatch {
        var batch = DirectoryChangeBatch()
        let recoveryMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagEventIdsWrapped
        )
        let rootsChangedMask = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let rootMutationMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed
        )


        for flags in eventFlags {
            if flags & recoveryMask != 0 {
                batch.requiresFullRescan = true
                batch.gitStateMayHaveChanged = true
            }
            if flags & rootsChangedMask != 0 {
                batch.requiresFullRescan = true
                batch.watchRootsChanged = true
                batch.gitStateMayHaveChanged = true
            }
        }
        for (path, flags) in zip(paths, eventFlags) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if flags & rootMutationMask != 0, configuration.isLogicalRoot(url) {
                batch.requiresFullRescan = true
                batch.watchRootsChanged = true
                batch.gitStateMayHaveChanged = true
            }
        }


        guard !batch.requiresFullRescan else { return batch }

        var workspacePaths = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if configuration.isGitContextPointer(url) {
                batch.gitStateMayHaveChanged = true
                batch.watchRootsChanged = true
                continue
            }
            if configuration.containsGitMetadataPath(url) {
                batch.gitStateMayHaveChanged = true
                continue
            }
            if configuration.containsRepositoryPath(url) {
                batch.gitStateMayHaveChanged = true
            }
            if configuration.containsWorkspacePath(url),
               !visibilityRules.isHiddenPath(url, relativeTo: configuration.workspaceRoot) {
                workspacePaths.insert(url.path)
            }
        }
        batch.workspacePaths = workspacePaths.sorted()
        return batch
    }

    deinit {
        stop()
    }
}
