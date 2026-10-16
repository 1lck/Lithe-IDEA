import Darwin
import Foundation

/// Stops every process of a POSIX session, not just its leader.
///
/// An interactive shell gives each job its own process group, so signalling
/// the shell or the shell's group leaves `mvn spring-boot:run`, `nohup` jobs
/// and disowned jobs running. All of them keep the session ID of the shell
/// that started them, which stays addressable after the shell itself exits.
enum MacProcessSessionTerminator {
    private static let pollingInterval: Duration = .milliseconds(20)

    /// Members of the session led by `leader`, including the leader while it
    /// is alive. Processes started before the leader cannot belong to it, which
    /// guards against a recycled session ID after the leader has exited.
    static func members(
        ofSessionLedBy leader: MacProcessIdentity,
        in snapshot: [MacProcessInfo] = MacProcessTable.snapshot()
    ) -> [MacProcessInfo] {
        snapshot.filter {
            $0.sessionID == leader.processID && $0.identity.startTime >= leader.startTime
        }
    }

    /// Sends `SIGHUP` and `SIGTERM` to every process group of the session,
    /// waits up to `gracePeriod`, then `SIGKILL`s whatever survived.
    ///
    /// - Returns: The members still alive after the forced phase; empty on success.
    @discardableResult
    static func terminate(
        sessionLedBy leader: MacProcessIdentity,
        gracePeriod: Duration = .milliseconds(1_500),
        forcedTerminationTimeout: Duration = .seconds(1)
    ) async -> [MacProcessInfo] {
        let initial = members(ofSessionLedBy: leader)
        guard !initial.isEmpty else { return [] }
        signal(initial, SIGHUP)
        signal(initial, SIGTERM)
        // A stopped job ignores SIGTERM until it is continued.
        signal(initial, SIGCONT)
        var survivors = await waitForExit(of: leader, timeout: gracePeriod)
        guard !survivors.isEmpty else { return [] }
        signal(survivors, SIGKILL)
        survivors = await waitForExit(of: leader, timeout: forcedTerminationTimeout)
        return survivors
    }

    private static func signal(_ processes: [MacProcessInfo], _ signal: Int32) {
        for group in Set(processes.map(\.processGroupID)) where group > 1 {
            _ = Darwin.kill(-group, signal)
        }
        // Members whose group lookup raced with a `setpgid` still get the signal.
        for process in processes where process.processID > 1 {
            _ = Darwin.kill(process.processID, signal)
        }
    }

    private static func waitForExit(
        of leader: MacProcessIdentity,
        timeout: Duration
    ) async -> [MacProcessInfo] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var survivors = members(ofSessionLedBy: leader)
        while !survivors.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: pollingInterval)
            survivors = members(ofSessionLedBy: leader)
        }
        return survivors
    }
}
