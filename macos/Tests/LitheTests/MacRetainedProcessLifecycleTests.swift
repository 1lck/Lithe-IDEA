import Darwin
import Foundation
import Testing
@testable import Lithe

@Suite("Retained process descendants")
struct MacRetainedProcessLifecycleTests {
    @Test func ancestryRequiresExactLiveIdentityAndDoesNotRetainSiblings() {
        let root = row(100, start: 10, parent: 50)
        let child = row(101, start: 11, parent: 100)
        let grandchild = row(102, start: 12, parent: 101)
        let sibling = row(103, start: 13, parent: 50)
        let infrastructure = row(50, start: 1, parent: 1)
        let snapshot = [grandchild, sibling, child, root, infrastructure]
        #expect(MacProcessScopeScanner.retainedIdentities([root.identity], snapshot: snapshot)
            == Set([root.identity, child.identity, grandchild.identity]))
        let recycledRoot = MacProcessIdentity(processID: 100, startTime: 9)
        #expect(MacProcessScopeScanner.retainedIdentities([recycledRoot], snapshot: snapshot) == [recycledRoot])
        #expect(MacProcessScopeScanner.retainedIdentities([root.identity], snapshot: [child, grandchild]) == [root.identity])
    }

    @Test func disconnectThenForkThenRootExitKeepsRecordedChildThroughFinalSweep() async throws {
        let fixture = try await RetainedForkFixture()
        defer { fixture.cleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-retained-\(UUID())")
        let store = MacProcessInstanceRecordStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = try #require(MacProcessTable.info(processID: getpid())?.identity)
        let instance = MacProcessInstance(
            scope: MacProcessScope(id: fixture.scope), store: store,
            record: MacProcessInstanceRecord(
                scope: fixture.scope, application: application, applicationSessionID: getsid(0)
            )
        )
        // This is the disconnect boundary: the task is kept, then its former
        // Agent infrastructure and an unretained sibling stay in the same scope.
        instance.retain([fixture.root])
        let sibling = try await fixture.launchUnretained()
        let infrastructure = try await fixture.launchUnretained()
        instance.approveTermination([sibling, infrastructure])
        try fixture.fork()
        #expect(await fixture.output.ready.waitUntilOpen())
        let child = try fixture.childIdentity()
        // Observe the persisted boundary, without calling instance.retained:
        // only the NOTE_FORK watcher can discover this child here.
        #expect(await persisted(child, scope: fixture.scope, store: store))
        try fixture.exitRoot()
        #expect(await fixture.exited.waitUntilOpen())
        instance.finalSweep(gracePeriod: 0)
        #expect(MacProcessTable.isAlive(child))
        #expect(!MacProcessTable.isAlive(sibling))
        #expect(!MacProcessTable.isAlive(infrastructure))
        #expect(store.load(scope: fixture.scope)?.retained.contains(child) == true)
    }

    @Test func unobservedOrphanDefersUntilStartupButApprovedSiblingEnds() async throws {
        let fixture = try await RetainedForkFixture()
        defer { fixture.cleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-unobserved-\(UUID())")
        let store = MacProcessInstanceRecordStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = try #require(MacProcessTable.info(processID: getpid())?.identity)
        var record = MacProcessInstanceRecord(
            scope: fixture.scope, application: application, applicationSessionID: getsid(0)
        )
        // The keep decision reached disk, but no tracker has observed a child.
        record.retained = [fixture.root]
        try store.save(record)
        let sibling = try await fixture.launchUnretained()
        try fixture.fork()
        #expect(await fixture.output.ready.waitUntilOpen())
        let child = try fixture.childIdentity()
        try fixture.exitRoot()
        #expect(await fixture.exited.waitUntilOpen())
        #expect(MacProcessTable.info(processID: child.processID)?.parentProcessID != fixture.root.processID)
        let instance = MacProcessInstance(scope: MacProcessScope(id: fixture.scope), store: store, record: record)
        instance.approveTermination([sibling])
        instance.finalSweep(gracePeriod: 0)
        #expect(MacProcessTable.isAlive(child))
        #expect(!MacProcessTable.isAlive(sibling))
        // The application's final sweep hands off to its supervisor on exit.
        // Deferred work must not be reinterpreted as an unattended crash kill.
        MacProcessSupervisor.recover(scope: fixture.scope, store: store, settings: ProcessTerminationSettings())
        #expect(MacProcessTable.isAlive(child))
        let saved = try #require(store.load(scope: fixture.scope))
        #expect(saved.awaitingStartupConfirmation == true)
        #expect(!saved.completedShutdown)
        #expect(!saved.retained.contains(child))
        let inventory = try MacProcessInventoryReader().inventory(
            scope: fixture.scope, mode: .leftover, applicationSessionID: saved.applicationSessionID,
            excluded: [getpid()], retained: saved.retained, context: .startupSweep
        )
        let item = try #require(inventory.items.first { $0.processes.contains(child.inventoryIdentity) })
        #expect(inventory.plan?.action(for: item.id) == .confirm)
    }

    @Test func crashAndStartupInventoriesExpandOnlyRetainedTaskAncestry() async throws {
        let fixture = try await RetainedForkFixture()
        defer { fixture.cleanup() }
        let sibling = try await fixture.launchUnretained()
        try fixture.fork()
        #expect(await fixture.output.ready.waitUntilOpen())
        let child = try fixture.childIdentity()
        let reader = MacProcessInventoryReader()
        for context in [ProcessLifecycleContext.crashRecovery, .startupSweep] {
            let inventory = try reader.inventory(
                scope: fixture.scope, mode: .leftover, excluded: [getpid()],
                retained: [fixture.root], context: context
            )
            let identities = Set(inventory.items.flatMap(\.processes).map(MacProcessIdentity.init))
            #expect(!identities.contains(child))
            #expect(!identities.contains(fixture.root))
            #expect(identities.contains(sibling))
        }
    }

    private func row(_ pid: pid_t, start: UInt64, parent: pid_t) -> MacProcessInfo {
        MacProcessInfo(identity: MacProcessIdentity(processID: pid, startTime: start),
                       parentProcessID: parent, processGroupID: 50, sessionID: 50,
                       hasControllingTerminal: false, name: "fixture")
    }

    private func persisted(_ identity: MacProcessIdentity, scope: String, store: MacProcessInstanceRecordStore) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if store.load(scope: scope)?.retained.contains(identity) == true { return true }
            // test-stability: allow(swift-real-sleep) reason: durable process-record writes have no consumer callback; bounded polling observes the recovery boundary rather than tracker internals.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// A real OS fork is unavoidable for kqueue coverage. Pipe commands control
/// fork and parent exit independently; no wall-clock delay orders the scenario.
private final class RetainedForkFixture {
    // Launching the real interpreter is an OS integration boundary. Hosted CI
    // exceeded the in-memory gate's 2s deadline before its first ready line.
    // Bound startup separately; fork and persistence deadlines stay unchanged.
    private static let startupTimeout: Duration = .seconds(5)
    let scope = UUID().uuidString
    let process = Process()
    let input = Pipe()
    let output = ForkOutput()
    let exited = TestGate()
    private let stdout = Pipe()
    private var unretained: [Process] = []
    private var unretainedIdentities: [MacProcessIdentity] = []
    private(set) var root = MacProcessIdentity(processID: 0, startTime: 0)

    init() async throws {
        // /usr/bin/python3 selects the installed Xcode tools. SIP-protected
        // /bin/sh and /bin/sleep can hide their environment from KERN_PROCARGS2.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os, signal, sys
        print("ready", flush=True)
        sys.stdin.readline()
        child = os.fork()
        if child == 0:
            signal.pause()
            os._exit(0)
        print(child, flush=True)
        sys.stdin.readline()
        """]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let output = output
        stdout.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
        let exited = exited
        process.terminationHandler = { _ in exited.open() }
        do {
            try process.run()
            try #require(
                await output.rootReady.waitUntilOpen(timeout: Self.startupTimeout),
                "Root fixture did not report ready: pid=\(process.processIdentifier), running=\(process.isRunning)"
            )
            root = try #require(MacProcessTable.info(processID: process.processIdentifier)?.identity)
        } catch {
            cleanup()
            throw error
        }
    }

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[MacProcessScope.environmentKey] = scope
        environment[MacProcessScope.agentEnvironmentKey] = "same-agent-for-all-fixtures"
        return environment
    }

    func fork() throws { try input.fileHandleForWriting.write(contentsOf: Data("fork\n".utf8)) }
    func exitRoot() throws { try input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8)) }

    func childIdentity() throws -> MacProcessIdentity {
        let pid = try #require(output.pid)
        return try #require(MacProcessTable.info(processID: pid)?.identity)
    }

    func launchUnretained() async throws -> MacProcessIdentity {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import signal; print('ready', flush=True); signal.pause()"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let ready = TestGate()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            if !handle.availableData.isEmpty { ready.open() }
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
        }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        unretained.append(process)
        let identity = try #require(MacProcessTable.info(processID: process.processIdentifier)?.identity)
        unretainedIdentities.append(identity)
        try #require(
            await ready.waitUntilOpen(timeout: Self.startupTimeout),
            "Sibling fixture did not report ready: pid=\(process.processIdentifier), running=\(process.isRunning)"
        )
        let arguments = try #require(MacProcessTable.arguments(processID: identity.processID), "Unable to read fixture arguments, errno: \(errno)")
        #expect(arguments.environment[MacProcessScope.environmentKey] == scope)
        return identity
    }

    func cleanup() {
        try? input.fileHandleForWriting.close()
        var identities = [root] + unretainedIdentities
        identities += MacProcessScopeScanner.processes(in: scope).map(\.info.identity)
        if let pid = output.pid, let child = MacProcessTable.info(processID: pid)?.identity { identities.append(child) }
        MacProcessScopeScanner.terminate(identities, gracePeriod: 0)
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
    }
}

private final class ForkOutput: @unchecked Sendable {
    let rootReady = TestGate()
    let ready = TestGate()
    private let lock = NSLock()
    private var bytes = Data()
    var pid: pid_t? {
        lock.withLock {
            String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }.first
        }
    }
    func append(_ data: Data) {
        let lines = lock.withLock {
            bytes.append(data)
            return String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        }
        if lines.contains("ready") { rootReady.open() }
        if lines.contains(where: { pid_t($0) != nil }) { ready.open() }
    }
}
