import CoreServices
import Foundation

final class DirectoryWatcher: @unchecked Sendable {
    private let root: URL
    private let visibilityRules: FileVisibilityRules
    private let queue = DispatchQueue(label: "app.lithe.file-events", qos: .utility)
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(
        root: URL,
        visibilityRules: FileVisibilityRules = .default,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.root = root
        self.visibilityRules = visibilityRules
        self.onChange = onChange
    }

    func start() {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info, eventCount > 0 else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let visiblePaths = paths.filter { path in
                !watcher.visibilityRules.isHiddenPath(
                    URL(fileURLWithPath: path),
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
            [root.path] as CFArray,
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

    deinit {
        stop()
    }
}
