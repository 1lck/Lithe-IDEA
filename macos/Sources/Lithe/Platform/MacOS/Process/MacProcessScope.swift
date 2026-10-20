import Darwin
import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// The ownership token of one running Lithe instance.
///
/// The token is exported into Lithe's own environment before any subprocess
/// starts, so every descendant inherits it, including descendants that call
/// `setsid` or are re-parented to `launchd`. A process without this exact token
/// is never shown, signalled, or swept: Lithe only manages what it started.
struct MacProcessScope: Equatable, Sendable {
    /// Inherited by every process this instance starts.
    static let environmentKey = "LITHE_PROCESS_SCOPE"
    /// Set on an Agent process; its descendants are that Agent's tasks.
    static let agentEnvironmentKey = "LITHE_AGENT_SCOPE"
    /// Set on a plugin backend; its descendants are what that backend left.
    static let pluginBackendEnvironmentKey = "LITHE_PLUGIN_BACKEND_SCOPE"

    /// The scope of the running application, once `activate()` has run.
    nonisolated(unsafe) private(set) static var current: MacProcessScope?

    let id: String

    /// Creates this launch's token and exports it. Call once, before anything
    /// can start a subprocess. A token inherited from another Lithe (for example
    /// one launched from a Lithe terminal) is replaced.
    @discardableResult
    static func activate() -> MacProcessScope {
        if let current { return current }
        let scope = MacProcessScope(id: UUID().uuidString)
        setenv(environmentKey, scope.id, 1)
        // Only the Agent host and the plugin backend host set these; a parent
        // Lithe's value would make every process of this instance look like
        // an Agent task or a plugin backend's leftover.
        unsetenv(agentEnvironmentKey)
        unsetenv(pluginBackendEnvironmentKey)
        current = scope
        return scope
    }
}

/// One process of a scope, with the facts used for classification.
struct MacScopedProcess: Sendable {
    let info: MacProcessInfo
    let arguments: MacProcessArguments
    var processScope: String? { arguments.environment[MacProcessScope.environmentKey] }
    var agentScope: String? { arguments.environment[MacProcessScope.agentEnvironmentKey] }
    var processID: pid_t { info.processID }

    /// The snapshot row Rust Core classifies.
    var snapshotEntry: ProcessSnapshotEntry {
        ProcessSnapshotEntry(
            processId: Int64(info.processID),
            startTime: info.identity.startTime,
            parentProcessId: Int64(info.parentProcessID),
            sessionId: Int64(info.sessionID),
            hasControllingTerminal: info.hasControllingTerminal,
            name: info.name,
            executablePath: arguments.executablePath,
            arguments: arguments.arguments,
            processScope: processScope,
            agentScope: agentScope,
            workingDirectory: MacProcessTable.workingDirectory(processID: info.processID)
        )
    }
}

extension MacProcessIdentity {
    init(_ identity: ProcessInventoryIdentity) {
        self.init(processID: pid_t(truncatingIfNeeded: identity.processId), startTime: identity.startTime)
    }

    var inventoryIdentity: ProcessInventoryIdentity {
        ProcessInventoryIdentity(processId: Int64(processID), startTime: startTime)
    }
}

/// Reads and ends processes that carry a scope token. Which of them are
/// Agent tasks, background services or terminal jobs is decided by Rust Core
/// (`processLifecycle.inventory`); this type only touches the process table.
enum MacProcessScopeScanner {
    /// Every live process of the current user carrying one of `scopes`,
    /// except the processes in `excluding`.
    static func processes(
        in scopes: Set<String>,
        excluding excluded: Set<pid_t> = [getpid()],
        snapshot: [MacProcessInfo] = MacProcessTable.snapshot()
    ) -> [MacScopedProcess] {
        snapshot.compactMap { info in
            guard !excluded.contains(info.processID),
                  let arguments = MacProcessTable.arguments(processID: info.processID),
                  let scope = arguments.environment[MacProcessScope.environmentKey],
                  scopes.contains(scope) else { return nil }
            return MacScopedProcess(info: info, arguments: arguments)
        }
    }

    static func processes(
        in scope: String,
        excluding excluded: Set<pid_t> = [getpid()],
        snapshot: [MacProcessInfo] = MacProcessTable.snapshot()
    ) -> [MacScopedProcess] {
        processes(in: [scope], excluding: excluded, snapshot: snapshot)
    }

    /// Expands only from an exact live identity. A shared Agent token, session,
    /// or a reused PID is never evidence that a sibling belongs to a kept task.
    /// Keep dead seeds too: a previously observed child may now be reparented.
    static func retainedIdentities(
        _ retained: [MacProcessIdentity],
        snapshot: [MacProcessInfo]
    ) -> Set<MacProcessIdentity> {
        let byID = Dictionary(snapshot.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Set(retained)
        var changed = true
        while changed {
            changed = false
            for child in snapshot where !result.contains(child.identity) {
                guard let parent = byID[child.parentProcessID],
                      result.contains(parent.identity),
                      child.identity.startTime >= parent.identity.startTime else { continue }
                result.insert(child.identity)
                changed = true
            }
        }
        return result
    }

    /// Ends the given processes: `SIGTERM` (and `SIGCONT` for stopped ones),
    /// then `SIGKILL` for survivors after `gracePeriod`. Only the exact
    /// identities are signalled, so a recycled PID is never hit.
    ///
    /// - Returns: The identities still alive afterwards.
    @discardableResult
    static func terminate(
        _ identities: [MacProcessIdentity],
        gracePeriod: TimeInterval,
        forcedTerminationTimeout: TimeInterval = 1
    ) -> [MacProcessIdentity] {
        var alive = identities.filter(MacProcessTable.isAlive)
        guard !alive.isEmpty else { return [] }
        send(SIGTERM, to: alive)
        send(SIGCONT, to: alive)
        alive = waitForExit(alive, timeout: gracePeriod)
        guard !alive.isEmpty else { return [] }
        send(SIGKILL, to: alive)
        return waitForExit(alive, timeout: forcedTerminationTimeout)
    }

    private static func send(_ signal: Int32, to identities: [MacProcessIdentity]) {
        for identity in identities where identity.processID > 1 && MacProcessTable.isAlive(identity) {
            _ = Darwin.kill(identity.processID, signal)
        }
    }

    private static func waitForExit(_ identities: [MacProcessIdentity], timeout: TimeInterval) -> [MacProcessIdentity] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var alive = identities.filter(MacProcessTable.isAlive)
        while !alive.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            alive = alive.filter(MacProcessTable.isAlive)
        }
        return alive
    }
}

/// What a Lithe instance leaves for its supervisor and for the next launch.
///
/// Stored under Application Support, never inside the app bundle: it changes on
/// every launch and must not alter the signed Sparkle baseline. One file per
/// instance; the supervisor deletes it once nothing of the instance remains
/// that a later launch has to ask about.
struct MacProcessInstanceRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    let scope: String
    let application: MacProcessIdentity
    /// Original application session, captured before the supervisor detaches.
    /// Older v1 records omit it; the recovery executor's session is not evidence.
    var applicationSessionID: pid_t? = nil
    var supervisor: MacProcessIdentity?
    /// Processes the user chose to keep; no sweep ever ends them.
    var retained: [MacProcessIdentity] = []
    /// Set once Lithe ran its normal shutdown.
    var completedShutdown = false
    /// Final cleanup deferred work to startup; the supervisor must not apply
    /// crash defaults to processes the user has not approved ending.
    var awaitingStartupConfirmation: Bool? = nil
    /// Set when the supervisor had to clean up after an abnormal exit.
    var recoveredAfterCrash = false
}

/// Reads and writes instance records in one directory.
struct MacProcessInstanceRecordStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    init(fileStorage: MacFileStorage = MacFileStorage()) {
        self.init(directory: fileStorage.applicationSupportDirectory()
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("ProcessLifecycle", isDirectory: true))
    }

    func url(for scope: String) -> URL {
        directory.appendingPathComponent("\(scope).json", isDirectory: false)
    }

    func load(scope: String) -> MacProcessInstanceRecord? {
        load(url(for: scope))
    }

    func save(_ record: MacProcessInstanceRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url(for: record.scope), options: .atomic)
    }

    func update(scope: String, _ change: (inout MacProcessInstanceRecord) -> Void) throws {
        guard var record = load(scope: scope) else { return }
        change(&record)
        try save(record)
    }

    func remove(scope: String) {
        try? FileManager.default.removeItem(at: url(for: scope))
    }

    /// Every readable record, oldest file first.
    func all() -> [MacProcessInstanceRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(load)
    }

    private func load(_ url: URL) -> MacProcessInstanceRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(MacProcessInstanceRecord.self, from: data),
              record.schemaVersion == MacProcessInstanceRecord.schemaVersion else { return nil }
        return record
    }
}
