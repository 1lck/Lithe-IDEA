import Darwin
import Foundation

/// The POSIX session of one terminal tab, and the evidence that its members
/// belong to that tab.
///
/// While the leader lives, nobody else can hold its session ID, and Darwin
/// does not hand out a PID that is still a live session's ID. Once the last
/// member is gone, though, the ID can be reused, and the newer session passes
/// any start-time check. So the members are pinned when the leader's exit is
/// observed or termination starts; from then on only they and their
/// descendants count, and a session ID alone is never proof again.
struct MacTerminalSessionOwnership: Equatable, Sendable {
    let leader: MacProcessIdentity
    /// Members pinned as evidence; `nil` until the leader exits or termination starts.
    private(set) var pinnedMembers: Set<MacProcessIdentity>?

    init(leader: MacProcessIdentity) {
        self.leader = leader
    }

    /// Pins the members provable now. Later calls keep the first evidence.
    ///
    /// - Returns: Whether any member is left to stop.
    @discardableResult
    mutating func pinMembers(snapshot: [MacProcessInfo] = MacProcessTable.snapshot()) -> Bool {
        if pinnedMembers == nil {
            pinnedMembers = Set(provableMembers(in: snapshot).map(\.identity))
        }
        return !members(in: snapshot).isEmpty
    }

    /// Members of the session that provably belong to this tab.
    func members(in snapshot: [MacProcessInfo] = MacProcessTable.snapshot()) -> [MacProcessInfo] {
        guard let pinnedMembers else { return provableMembers(in: snapshot) }
        let owned = MacProcessScopeScanner.retainedIdentities(Array(pinnedMembers), snapshot: snapshot)
        return snapshot.filter { owned.contains($0.identity) && isCandidate($0) }
    }

    /// Without pinned evidence, the session ID is trusted only while no other
    /// process holds the leader's PID. The remaining window is the moment
    /// between the leader's exit and the terminal reporting it.
    private func provableMembers(in snapshot: [MacProcessInfo]) -> [MacProcessInfo] {
        if snapshot.contains(where: { $0.processID == leader.processID && $0.identity != leader }) { return [] }
        return snapshot.filter(isCandidate)
    }

    private func isCandidate(_ process: MacProcessInfo) -> Bool {
        process.sessionID == leader.processID && process.identity.startTime >= leader.startTime
    }
}

/// Stops every process of a POSIX session, not just its leader.
///
/// An interactive shell gives each job its own process group, so signalling
/// the shell or the shell's group leaves `mvn spring-boot:run`, `nohup` jobs
/// and disowned jobs running. All of them keep the session ID of the shell
/// that started them, which stays addressable after the shell itself exits.
enum MacProcessSessionTerminator {
    private static let pollingInterval: Duration = .milliseconds(20)

    /// Sends `SIGHUP` and `SIGTERM` to every process group of the session,
    /// waits up to `gracePeriod`, then `SIGKILL`s whatever survived.
    ///
    /// - Returns: The members still alive after the forced phase; empty on success.
    @discardableResult
    static func terminate(
        _ session: MacTerminalSessionOwnership,
        gracePeriod: Duration = .milliseconds(1_500),
        forcedTerminationTimeout: Duration = .seconds(1)
    ) async -> [MacProcessInfo] {
        var session = session
        // The leader usually exits on SIGHUP; survivors must still be tracked.
        guard session.pinMembers() else { return [] }
        let initial = session.members()
        signal(initial, SIGHUP, session: session)
        signal(initial, SIGTERM, session: session)
        // A stopped job ignores SIGTERM until it is continued.
        signal(initial, SIGCONT, session: session)
        var survivors = await waitForExit(of: session, timeout: gracePeriod)
        guard !survivors.isEmpty else { return [] }
        signal(survivors, SIGKILL, session: session)
        survivors = await waitForExit(of: session, timeout: forcedTerminationTimeout)
        return survivors
    }

    private static func signal(_ processes: [MacProcessInfo], _ signal: Int32, session: MacTerminalSessionOwnership) {
        // Whole groups only while the leader still proves the session; a group
        // ID of an exited session could already belong to someone else.
        if MacProcessTable.isAlive(session.leader) {
            for group in Set(processes.map(\.processGroupID)) where group > 1 {
                _ = Darwin.kill(-group, signal)
            }
        }
        // Members whose group lookup raced with a `setpgid` still get the signal.
        for process in processes where process.processID > 1 {
            _ = Darwin.kill(process.processID, signal)
        }
    }

    private static func waitForExit(
        of session: MacTerminalSessionOwnership,
        timeout: Duration
    ) async -> [MacProcessInfo] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var survivors = session.members()
        while !survivors.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: pollingInterval)
            survivors = session.members()
        }
        return survivors
    }
}
