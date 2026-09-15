import AppKit
import CoreServices
import Foundation

/// Routes native file events without reading document contents or starting a stream.
struct MacDocumentEventRouter {
    private let documents: [(url: URL, paths: Set<String>)]

    init(urls: [URL]) {
        // FSEvents reports physical paths; keep logical aliases such as /tmp too.
        documents = urls.map { url in
            (url, Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]))
        }
    }

    func affectedDocuments(paths: [String], eventFlags: [FSEventStreamEventFlags]) -> [URL] {
        let recoveryMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagRootChanged
        )
        guard paths.count == eventFlags.count,
              !eventFlags.contains(where: { $0 & recoveryMask != 0 }) else {
            return documents.map(\.url)
        }
        let parentMutationMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed
        )
        let events = zip(paths, eventFlags).map { path, flags in
            (path: URL(fileURLWithPath: path).standardizedFileURL.path,
             parentChanged: flags & parentMutationMask != 0)
        }
        return documents.filter { document in
            events.contains { event in
                document.paths.contains { path in
                    path == event.path || (event.parentChanged && path.hasPrefix(event.path + "/"))
                }
            }
        }.map(\.url)
    }
}

/// Open documents, including standalone files, retain parent watches until their owner closes.
final class MacDocumentObservation: DocumentFileObservation, @unchecked Sendable {
    private final class CallbackContext {
        weak var owner: MacDocumentObservation?
        init(_ owner: MacDocumentObservation) { self.owner = owner }
    }

    private let lock = NSRecursiveLock()
    private let urls: [URL]
    private let eventRouter: MacDocumentEventRouter
    private let onChange: @Sendable ([URL]) -> Void
    private var stream: FSEventStreamRef?
    private var focusObserver: NSObjectProtocol?
    private var cancelled = false

    init(urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) {
        self.urls = urls
        eventRouter = MacDocumentEventRouter(urls: urls)
        self.onChange = onChange
        restart()
        focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.restart()
        }
    }

    private func restart() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        stopStream()
        let callbackContext = CallbackContext(self)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<CallbackContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<CallbackContext>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, eventCount, eventPaths, eventFlags, _ in
            guard let context, eventCount > 0 else { return }
            let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
            callbackContext.owner?.changed(paths: paths, eventFlags: flags)
        }
        // Parent streams also see descendant build outputs. Only recovery events
        // require all owned documents; ordinary events are routed by path below.
        let roots = Array(Set(urls.map { $0.deletingLastPathComponent().path })).sorted()
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { NSLog("Document watch unavailable; saves remain guarded") }
        } else { NSLog("Could not create document watch; saves remain guarded") }
        onChange(urls)
    }

    private func changed(paths: [String], eventFlags: [FSEventStreamEventFlags]) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        let affected = eventRouter.affectedDocuments(paths: paths, eventFlags: eventFlags)
        if !affected.isEmpty { onChange(affected) }
    }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        stopStream()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
    }

    deinit { cancel() }
}
