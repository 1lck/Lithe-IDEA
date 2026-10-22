import Foundation
import WebKit

/// Which URL scheme tasks WebKit is still waiting for.
///
/// A handler that reads files off the main thread answers later, but WebKit
/// forbids touching a task after it called `stop`. A task is registered when it
/// starts, `stop` withdraws it, and whoever has an answer must `claim` it first:
/// a claim succeeds once and never after a stop. Deliver the answer right after
/// a successful claim, on the main thread where `stop` arrives, so no stop can
/// come between the two.
final class LocalFileSchemeTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var live = Set<ObjectIdentifier>()

    func register(_ task: any WKURLSchemeTask) -> ObjectIdentifier {
        let id = ObjectIdentifier(task)
        lock.withLock { _ = live.insert(id) }
        return id
    }

    func stop(_ task: any WKURLSchemeTask) {
        lock.withLock { _ = live.remove(ObjectIdentifier(task)) }
    }

    func claim(_ id: ObjectIdentifier) -> Bool {
        lock.withLock { live.remove(id) != nil }
    }
}

enum LocalFileContainment {
    /// Whether `candidate` is `root` or below it. Whole path components are
    /// compared, so `/a/bc` is not inside `/a/b`. Both URLs should be
    /// standardized and have their symbolic links resolved first.
    static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
