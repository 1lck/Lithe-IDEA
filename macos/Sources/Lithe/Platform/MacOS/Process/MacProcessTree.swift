import Darwin
import Foundation

/// Tracks a launched process and every descendant observed during termination.
///
/// Foundation's `Process.terminate()` only signals the direct child. Toolchains
/// commonly insert shells, Maven, or Java launchers, so termination must retain
/// descendant PIDs before the root can exit and orphan them.
final class MacProcessTree: @unchecked Sendable {
    private static let pollingInterval: Duration = .milliseconds(10)

    private let rootPID: pid_t
    private let lock = NSLock()
    private var knownPIDs: Set<pid_t>

    init(rootPID: pid_t) {
        self.rootPID = rootPID
        knownPIDs = [rootPID]
    }

    /// Starts bounded graceful termination and escalates every surviving member.
    @discardableResult
    func terminate(
        gracePeriod: Duration = .milliseconds(200),
        forcedTerminationTimeout: Duration = .seconds(1)
    ) -> Task<Bool, Never> {
        signal(SIGTERM)
        return Task { [self] in
            try? await Task.sleep(for: gracePeriod)
            if hasRunningProcesses {
                signal(SIGKILL)
            }
            return await waitUntilExited(timeout: forcedTerminationTimeout)
        }
    }

    /// Performs the same process-tree cleanup for synchronous process runners.
    func terminateAndWait(
        gracePeriod: TimeInterval = 0.2,
        forcedTerminationTimeout: TimeInterval = 1
    ) {
        signal(SIGTERM)
        guard !waitUntilExited(timeout: gracePeriod) else { return }
        signal(SIGKILL)
        _ = waitUntilExited(timeout: forcedTerminationTimeout)
    }

    var hasRunningProcesses: Bool {
        trackedPIDs().contains(where: Self.isRunning)
    }

    private func signal(_ signal: Int32) {
        for pid in trackedPIDs() where Self.isRunning(pid) {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func trackedPIDs() -> [pid_t] {
        let roots = lock.withLock { Array(knownPIDs) }
        var discovered = Set<pid_t>()
        for pid in roots where Self.isRunning(pid) {
            Self.collectProcessTree(rootPID: pid, into: &discovered)
        }
        return lock.withLock {
            knownPIDs.formUnion(discovered)
            let descendants = knownPIDs.filter { $0 != rootPID }.sorted(by: >)
            return descendants + [rootPID]
        }
    }

    private func waitUntilExited(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while hasRunningProcesses, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !hasRunningProcesses
    }

    private func waitUntilExited(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while hasRunningProcesses, clock.now < deadline {
            try? await Task.sleep(for: Self.pollingInterval)
        }
        return !hasRunningProcesses
    }

    private static func collectProcessTree(rootPID: pid_t, into result: inout Set<pid_t>) {
        guard rootPID > 0, result.insert(rootPID).inserted else { return }
        for childPID in childPIDs(of: rootPID) {
            collectProcessTree(rootPID: childPID, into: &result)
        }
    }

    private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let requiredBytes = proc_listchildpids(parentPID, nil, 0)
        guard requiredBytes > 0 else { return [] }
        let capacity = max(
            Int(requiredBytes) / MemoryLayout<pid_t>.stride,
            1
        )
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}
