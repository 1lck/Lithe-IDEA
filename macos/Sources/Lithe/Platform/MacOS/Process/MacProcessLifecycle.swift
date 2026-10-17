import Darwin
import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// The lifecycle state of the running Lithe instance: its scope token, its
/// instance record and its supervisor.
///
/// Lifetime: created by `MacApplicationEntryPoint` before any UI or subprocess
/// exists; the record file lives in Application Support, never in the bundle.
final class MacProcessInstance: @unchecked Sendable {
    nonisolated(unsafe) private(set) static var current: MacProcessInstance?

    let scope: MacProcessScope
    let store: MacProcessInstanceRecordStore
    let applicationSessionID: pid_t?
    private let lock = NSLock()
    private var record: MacProcessInstanceRecord
    private var retentionTracker: MacRetainedProcessTracker?
    private var approvedTermination: Set<MacProcessIdentity> = []

    init(scope: MacProcessScope, store: MacProcessInstanceRecordStore, record: MacProcessInstanceRecord) {
        self.scope = scope
        self.store = store
        self.applicationSessionID = record.applicationSessionID
        self.record = record
        retentionTracker = MacRetainedProcessTracker { [weak self] identities in
            self?.persistRetained(identities)
        }
        retentionTracker?.refresh(adding: record.retained)
    }

    /// Exports the scope token, writes the instance record and starts the
    /// supervisor that cleans up if this process dies without quitting.
    @discardableResult
    static func activate(store: MacProcessInstanceRecordStore = MacProcessInstanceRecordStore()) -> MacProcessInstance? {
        if let current { return current }
        let scope = MacProcessScope.activate()
        guard let application = MacProcessTable.info(processID: getpid())?.identity else { return nil }
        let instance = MacProcessInstance(
            scope: scope,
            store: store,
            record: MacProcessInstanceRecord(
                scope: scope.id, application: application, applicationSessionID: getsid(0)
            )
        )
        current = instance
        instance.persist()
        if let supervisor = MacProcessSupervisor.launch(scope: scope.id, applicationProcessID: getpid()) {
            instance.mutate { $0.supervisor = supervisor }
        }
        return instance
    }

    var supervisor: MacProcessIdentity? { lock.withLock { record.supervisor } }
    var retained: [MacProcessIdentity] {
        if let identities = retentionTracker?.refresh() {
            // Another event callback may still be waiting to persist its delta.
            // The tracker is authoritative for all identities already observed.
            persistRetained(Array(identities))
        }
        return lock.withLock { record.retained }
    }

    /// Processes that are never signalled by this instance's sweeps.
    var excludedProcessIDs: Set<pid_t> {
        var excluded: Set<pid_t> = [getpid()]
        if let supervisor { excluded.insert(supervisor.processID) }
        return excluded
    }

    /// Keeps `identities` running past quit and crash recovery.
    func retain(_ identities: [MacProcessIdentity]) {
        guard !identities.isEmpty else { return }
        retentionTracker?.refresh(adding: identities)
    }

    private func persistRetained(_ identities: [MacProcessIdentity]) {
        mutate { record in
            record.retained = Array(Set(record.retained).union(identities))
                .sorted { ($0.processID, $0.startTime) < ($1.processID, $1.startTime) }
        }
    }

    /// Records the exact identities the user or a connection close authorized
    /// ending. A later process with a reused PID is never covered by that choice.
    func approveTermination(_ identities: [MacProcessIdentity]) {
        lock.withLock { approvedTermination.formUnion(identities) }
    }

    /// Applies the final Core plan after modules stop. Agent processes first
    /// observed after confirmation are deferred for the next startup, where they
    /// can be confirmed individually; they are not silently treated as retained.
    func finalSweep(gracePeriod: TimeInterval) {
        mutate { $0.awaitingStartupConfirmation = true }
        let seeds = retained
        let snapshot = MacProcessTable.snapshot()
        let kept = MacProcessScopeScanner.retainedIdentities(seeds, snapshot: snapshot)
        persistRetained(Array(kept))
        let approved = lock.withLock { Array(approvedTermination) }
        guard let inventory = try? MacProcessInventoryReader().inventory(
            scope: scope.id, mode: .leftover, applicationSessionID: applicationSessionID,
            excluded: excludedProcessIDs, retained: Array(kept),
            approvedTermination: approved, context: .finalSweep, snapshot: snapshot
        ), let plan = inventory.plan else { return }
        let ended = inventory.items.filter { plan.action(for: $0.id) == .terminate }
            .flatMap { $0.processes.map(MacProcessIdentity.init) }
        let survivors = MacProcessScopeScanner.terminate(ended, gracePeriod: gracePeriod)
        let hasUnconfirmed = plan.decisions.contains { $0.action == .defer }
        // Keep the record recoverable when a fast-fork descendant lost its
        // ancestry before either watcher or snapshot could observe it.
        mutate {
            $0.completedShutdown = !hasUnconfirmed && survivors.isEmpty
            $0.awaitingStartupConfirmation = !$0.completedShutdown
        }
    }

    private func mutate(_ change: (inout MacProcessInstanceRecord) -> Void) {
        lock.withLock {
            change(&record)
            saveLocked()
        }
    }

    private func persist() {
        lock.withLock { saveLocked() }
    }

    private func saveLocked() {
        do {
            try store.save(record)
        } catch {
            FileHandle.standardError.write(Data("Could not save the process lifecycle record: \(error)\n".utf8))
        }
    }
}

/// The helper process that outlives a crashed Lithe and ends what it left.
///
/// It is the application binary started with `--lithe-process-supervisor`,
/// so it needs no extra bundle content and is signed with the app. It writes
/// nothing except the instance record in Application Support.
enum MacProcessSupervisor {
    static let argument = "--lithe-process-supervisor"

    static func launch(scope: String, applicationProcessID: pid_t) -> MacProcessIdentity? {
        guard let executable = Bundle.main.executablePath else { return nil }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session: closing a terminal or Lithe's process group must not take it along.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&fileActions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        let arguments = [executable, argument, scope, String(applicationProcessID)]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var processID: pid_t = 0
        guard posix_spawn(&processID, executable, &fileActions, &attributes, &argv, environ) == 0 else { return nil }
        return MacProcessTable.info(processID: processID)?.identity
    }

    /// Supervisor entry point; never returns.
    static func run(arguments: [String]) -> Never {
        guard arguments.count >= 2, let applicationProcessID = pid_t(arguments[1]) else { exit(EX_USAGE) }
        let scope = arguments[0]
        signal(SIGHUP, SIG_IGN)
        waitForExit(of: applicationProcessID)
        recover(scope: scope, store: MacProcessInstanceRecordStore(), settings: storedSettings())
        exit(EXIT_SUCCESS)
    }

    private static func waitForExit(of processID: pid_t) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(processID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT,
            data: 0,
            udata: nil
        )
        var event = kevent()
        // Registering fails with ESRCH when the application is already gone.
        while kevent(queue, &change, 1, &event, 1, nil) < 0 {
            guard errno == EINTR else { return }
        }
    }

    /// Applies the crash-recovery policy to an instance whose application has
    /// exited. A normal quit already swept, so only its record is removed.
    static func recover(
        scope: String,
        store: MacProcessInstanceRecordStore,
        settings: ProcessTerminationSettings,
        reader: MacProcessInventoryReader = MacProcessInventoryReader()
    ) {
        guard var record = store.load(scope: scope) else { return }
        guard !record.completedShutdown else {
            store.remove(scope: scope)
            return
        }
        if record.awaitingStartupConfirmation == true {
            record.supervisor = nil
            try? store.save(record)
            return
        }
        let snapshot = MacProcessTable.snapshot()
        record.retained = Array(MacProcessScopeScanner.retainedIdentities(record.retained, snapshot: snapshot))
            .sorted { ($0.processID, $0.startTime) < ($1.processID, $1.startTime) }
        // Without a plan nothing is ended: the next launch asks instead.
        guard let inventory = try? reader.inventory(
            scope: scope,
            mode: .leftover,
            applicationSessionID: record.applicationSessionID,
            excluded: [getpid()],
            retained: record.retained,
            context: .crashRecovery,
            settings: settings,
            snapshot: snapshot
        ), let plan = inventory.plan else {
            record.supervisor = nil
            record.recoveredAfterCrash = true
            try? store.save(record)
            return
        }
        let gracePeriod = TimeInterval(plan.gracefulStopMilliseconds) / 1_000
        var leftForStartup = false
        for item in inventory.items {
            if plan.action(for: item.id) == .terminate {
                let survivors = MacProcessScopeScanner.terminate(
                    item.processes.map(MacProcessIdentity.init), gracePeriod: gracePeriod
                )
                leftForStartup = leftForStartup || !survivors.isEmpty
            } else {
                leftForStartup = true
            }
        }
        guard leftForStartup else {
            store.remove(scope: scope)
            return
        }
        record.supervisor = nil
        record.recoveredAfterCrash = true
        try? store.save(record)
    }

    static func storedSettings(defaults: UserDefaults = .standard) -> ProcessTerminationSettings {
        guard let data = defaults.data(forKey: AppSettings.processTerminationKey),
              let settings = try? JSONDecoder().decode(ProcessTerminationSettings.self, from: data) else {
            return ProcessTerminationSettings()
        }
        return settings
    }
}

/// What earlier instances that did not quit normally left behind.
struct MacStartupProcessSweep: Sendable {
    struct Leftovers: Sendable {
        let scope: String
        let inventory: ProcessInventory
    }

    /// Leftovers of instances whose application and supervisor are both gone,
    /// classified and decided for `startupSweep`. Records with nothing left
    /// are removed.
    static func leftovers(
        store: MacProcessInstanceRecordStore,
        currentScope: String,
        excluding excluded: Set<pid_t>,
        settings: ProcessTerminationSettings,
        reader: MacProcessInventoryReader = MacProcessInventoryReader()
    ) -> [Leftovers] {
        var leftovers: [Leftovers] = []
        let snapshot = MacProcessTable.snapshot()
        for var record in store.all() where record.scope != currentScope {
            if MacProcessTable.isAlive(record.application) { continue }
            if let supervisor = record.supervisor, MacProcessTable.isAlive(supervisor) { continue }
            let expanded = MacProcessScopeScanner.retainedIdentities(record.retained, snapshot: snapshot)
            if expanded != Set(record.retained) {
                record.retained = expanded.sorted { ($0.processID, $0.startTime) < ($1.processID, $1.startTime) }
                do {
                    try store.save(record)
                } catch {
                    FileHandle.standardError.write(Data("Could not save retained startup descendants: \(error)\n".utf8))
                }
            }
            guard let inventory = try? reader.inventory(
                scope: record.scope,
                mode: .leftover,
                applicationSessionID: record.applicationSessionID,
                excluded: excluded,
                retained: record.retained,
                context: .startupSweep,
                settings: settings,
                snapshot: snapshot
            ) else { continue }
            if inventory.items.isEmpty {
                store.remove(scope: record.scope)
            } else {
                leftovers.append(Leftovers(scope: record.scope, inventory: inventory))
            }
        }
        return leftovers
    }
}
