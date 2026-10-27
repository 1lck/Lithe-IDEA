import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Remote directory observation") @MainActor
struct RemoteDirectoryObservationTests {
    @Test
    func hostEventsMapToWorkspaceURLsAndCancelledGenerationsCannotRefresh() async throws {
        let root = URL(fileURLWithPath: "/fixture/placeholder")
        let registry = RemoteWorkspaceRegistry()
        let binding = RemoteWorkspaceBinding(root: root, remoteRoot: "/host/project", sessionID: "one", connectionID: UUID())
        registry.register(binding)
        let host = WatchFixture()
        let batches = WatchBatches()
        let source = RemoteDirectoryObservation(
            configuration: DirectoryWatchConfiguration(workspaceRoot: root, gitContext: nil),
            visibilityRules: FileVisibilityRules(hiddenDirectoryNames: [".git"], hiddenFilePatterns: []),
            binding: binding, registry: registry, transport: host, onChange: batches.append
        )
        defer { source.stop(); host.finish() }
        source.start()
        #expect(await watchEventually { host.active == 1 })
        #expect(host.requests == ["one:/host/project"])
        host.emit(.started)
        #expect(batches.values.last?.requiresFullRescan == true)
        host.emit(.changed(paths: ["/host/project/src/A.java", "/host/project-neighbor/a"], overflow: false))
        #expect(batches.values.last?.workspacePaths == [root.appendingPathComponent("src/A.java").path])
        host.emit(.changed(paths: [], overflow: true))
        #expect(batches.values.last?.requiresFullRescan == true)
        host.emit(.invalidated(rootRemoved: true))
        #expect(batches.values.last?.watchRootsChanged == true)
        let count = batches.values.count
        source.stop()
        // The fake deliberately retains its old callback after cancellation.
        host.emit(.changed(paths: ["/host/project/stale"], overflow: false))
        #expect(batches.values.count == count)
        #expect(await watchEventually { host.active == 0 })
    }

    @Test
    func documentObservationsReportExternalChangesAndReleaseHostWatches() async throws {
        let root = URL(fileURLWithPath: "/fixture/placeholder")
        let registry = RemoteWorkspaceRegistry()
        registry.register(RemoteWorkspaceBinding(root: root, remoteRoot: "/host/project", sessionID: "one", connectionID: UUID()))
        let host = WatchFixture()
        let files = RemoteRoutingFileOperations(local: MacWorkspaceFileOperations(), registry: registry, transport: host)
        let changes = WatchDocuments()
        let a = root.appendingPathComponent("src/A.java")
        let b = root.appendingPathComponent("B.java")
        let observation = files.observeDocuments(at: [a, b], onChange: changes.append)
        defer { observation.cancel(); host.finish() }
        #expect(await watchEventually { host.active == 1 })
        host.emit(.changed(paths: ["/host/project/src"], overflow: false))
        #expect(changes.values.last == [a])
        host.emit(.changed(paths: [], overflow: true))
        #expect(changes.values.last == [a, b])
        observation.cancel()
        #expect(await watchEventually { host.active == 0 })
    }
}

@MainActor private func watchEventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private final class WatchFixture: RemoteWorkspaceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    private var recorded: [String] = []
    private var callback: (@Sendable (RemoteWatchEvent) -> Void)?
    private var continuation: AsyncStream<Void>.Continuation?
    var active: Int { lock.withLock { runs } }
    var requests: [String] { lock.withLock { recorded } }

    func watch(root: String, session: String, onEvent: @escaping @Sendable (RemoteWatchEvent) -> Void) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            runs += 1
            recorded.append(session + ":" + root)
            callback = onEvent
            self.continuation = continuation
        }
        defer { lock.withLock { runs -= 1; self.continuation = nil } }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func emit(_ event: RemoteWatchEvent) { lock.withLock { callback }?(event) }
    func finish() { lock.withLock { continuation }?.finish() }
    func listDirectory(_ path: String, session id: String) throws -> [RemoteDirectoryEntry] { [] }
    func readFile(_ path: String, session id: String) throws -> (data: Data, version: RemoteFileVersion) { throw CocoaError(.fileNoSuchFile) }
    func writeFile(_ data: Data, to path: String, expected: RemoteFileVersion?, session id: String) throws -> RemoteWriteOutcome { .conflict }
}

private final class WatchBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DirectoryChangeBatch] = []
    var values: [DirectoryChangeBatch] { lock.withLock { recorded } }
    func append(_ batch: DirectoryChangeBatch) { lock.withLock { recorded.append(batch) } }
}

private final class WatchDocuments: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[URL]] = []
    var values: [[URL]] { lock.withLock { recorded } }
    func append(_ urls: [URL]) { lock.withLock { recorded.append(urls) } }
}
