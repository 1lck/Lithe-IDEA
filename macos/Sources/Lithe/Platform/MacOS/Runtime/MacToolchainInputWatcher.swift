import CoreServices
import Foundation

/// Watches provider inputs outside the workspace with one FSEvents stream. A named file
/// is watched through its parent, so creating an absent input is reported too.
struct MacToolchainInputWatcher: ToolchainInputWatching {
    /// Bounds the stream; providers may name at most 256 paths per reply.
    static let pathBudget = 1_024

    func watch(paths: [String], onChange: @escaping @Sendable () -> Void) -> AnyObject? {
        let roots = Self.roots(of: paths)
        return roots.isEmpty ? nil : Observation(roots: roots, onChange: onChange)
    }

    /// The nearest existing directory of each path, without repeats.
    static func roots(of paths: [String]) -> [String] {
        var roots: Set<String> = []
        for path in paths.prefix(pathBudget) where path.hasPrefix("/") {
            var current = path
            var isDirectory: ObjCBool = false
            while current != "/" && !(FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory) && isDirectory.boolValue) {
                current = (current as NSString).deletingLastPathComponent
            }
            if current != "/" { roots.insert(current) }
        }
        return roots.sorted()
    }

    private final class Observation {
        private final class Callback {
            let onChange: @Sendable () -> Void
            init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        }

        private let queue = DispatchQueue(label: "app.lithe.toolchain-inputs", qos: .utility)
        private let callback: Callback
        private var stream: FSEventStreamRef?

        init(roots: [String], onChange: @escaping @Sendable () -> Void) {
            callback = Callback(onChange)
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            guard let stream = FSEventStreamCreate(
                nil,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange()
                },
                &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            ) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
        }

        deinit {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // Invalidation stops new callbacks; this drains one already on the queue.
            queue.sync {}
        }
    }
}
