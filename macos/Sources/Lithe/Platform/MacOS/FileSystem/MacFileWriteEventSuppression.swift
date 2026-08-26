import Foundation

/// Suppresses the one FSEvents notification produced by a successful app-owned write.
/// Entries expire quickly so external edits to the same file are never hidden long term.
enum MacFileWriteEventSuppression {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var paths: [String: Date] = [:]
    private static let lifetime: TimeInterval = 2

    static func markWritten(_ url: URL, now: Date = Date()) {
        lock.withLock {
            removeExpired(now: now)
            paths[url.standardizedFileURL.path] = now.addingTimeInterval(lifetime)
        }
    }

    static func consume(_ url: URL, now: Date = Date()) -> Bool {
        lock.withLock {
            removeExpired(now: now)
            return paths.removeValue(forKey: url.standardizedFileURL.path) != nil
        }
    }

    private static func removeExpired(now: Date) {
        paths = paths.filter { $0.value > now }
    }
}
