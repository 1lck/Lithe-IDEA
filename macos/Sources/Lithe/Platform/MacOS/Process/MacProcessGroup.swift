import Darwin
import Foundation

/// Owns the dedicated process group assigned while a subprocess is spawned.
///
/// A process group remains addressable after its leader exits and descendants
/// are reparented, unlike a PID tree reconstructed during termination.
final class MacProcessGroup: @unchecked Sendable {
    private static let pollingInterval: Duration = .milliseconds(10)

    let processGroupID: pid_t

    init(processGroupID: pid_t) {
        self.processGroupID = processGroupID
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

    /// Performs the same process-group cleanup for synchronous process runners.
    @discardableResult
    func terminateAndWait(
        gracePeriod: TimeInterval = 0.2,
        forcedTerminationTimeout: TimeInterval = 1
    ) -> Bool {
        signal(SIGTERM)
        guard !waitUntilExited(timeout: gracePeriod) else { return true }
        signal(SIGKILL)
        return waitUntilExited(timeout: forcedTerminationTimeout)
    }

    var hasRunningProcesses: Bool {
        guard processGroupID > 0 else { return false }
        errno = 0
        return Darwin.kill(-processGroupID, 0) == 0 || errno == EPERM
    }

    private func signal(_ signal: Int32) {
        guard processGroupID > 0 else { return }
        // A negative PID targets every member, including descendants whose
        // original parent has exited and whose standard streams are closed.
        _ = Darwin.kill(-processGroupID, signal)
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
}
