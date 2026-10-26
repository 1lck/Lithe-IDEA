import Combine
import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

// Note: .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

private final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class MemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(key: String) -> String? { lock.withLock { values[key] } }
    func write(_ value: String, key: String) throws { lock.withLock { values[key] = value } }
    func delete(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
    var keys: [String] { lock.withLock { Array(values.keys) } }
}

/// Plays OpenSSH: asks `prompts` one at a time, each only after the previous
/// one was answered, then reports `result`.
private final class ScriptedProber: RemoteConnectionProbing, RemoteSessionConnecting, @unchecked Sendable {
    let prompts: [RemoteAuthenticationPrompt]
    let result: RemoteProbeResult
    private let lock = NSLock()
    private var recorded: [(id: String, answer: String?)] = []
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(prompts: [RemoteAuthenticationPrompt], result: RemoteProbeResult) {
        self.prompts = prompts
        self.result = result
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    var answers: [(id: String, answer: String?)] { lock.withLock { recorded } }

    func probe(
        _ target: RemoteSSHTarget, onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<RemoteProbeResult, RemoteProbeFailure> {
        var iterator = stream.makeAsyncIterator()
        for prompt in prompts {
            onPrompt(prompt)
            _ = await iterator.next()
        }
        return .success(result)
    }

    func answer(_ requestID: String, with answer: String?) -> Bool {
        lock.withLock { recorded.append((requestID, answer)) }
        continuation.yield()
        return true
    }

    func connect(
        _ target: RemoteSSHTarget, servers: RemoteServerBundle,
        onPrompt: @escaping @Sendable (RemoteAuthenticationPrompt) -> Void
    ) async -> Result<RemoteConnectResult, RemoteProbeFailure> {
        .failure(RemoteProbeFailure(code: "unused", message: "unused"))
    }

    func readDirectory(_ path: String, session id: String) async -> Result<[RemoteDirectoryEntry], RemoteProbeFailure> {
        .success([])
    }

    func disconnect(session id: String) async {}
}

private struct NoLocator: RemoteHostLocating {
    func resolveAddress(of host: String) async -> String? { nil }
    func locate(_ address: String) async -> Result<RemoteHostLocation, RemoteProbeFailure> {
        .failure(RemoteProbeFailure(code: "unused", message: "unused"))
    }
}

/// Waits for `condition` on the main actor, failing after a short local
/// deadline instead of hanging the suite.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private func prompt(_ id: String, _ text: String, secret: Bool = true, attempt: Int = 1) -> RemoteAuthenticationPrompt {
    RemoteAuthenticationPrompt(requestId: id, prompt: text, secret: secret, attempt: attempt)
}

private let connectedResult = RemoteProbeResult(
    status: .connected,
    host: RemoteProbedHost(
        system: "Linux", machine: "x86_64", homeDirectory: "/root",
        serverTarget: "x86_64-unknown-linux-musl", details: RemoteHostDetails()
    ),
    diagnostics: ""
)

@MainActor
private func passwordFeature(
    prompts: [RemoteAuthenticationPrompt], savedSecret: String?
) throws -> (RemoteConnectionsFeatureModel, ScriptedProber) {
    let secure = MemorySecureStore()
    let store = RemoteConnectionStore(store: MemoryKeyValueStore(), secureStore: secure)
    let connection = RemoteSSHConnection(host: "devbox", user: "root", authentication: .password, remembersSecret: savedSecret != nil)
    try store.save([connection])
    if let savedSecret { try store.saveSecret(savedSecret, for: connection.id) }
    let prober = ScriptedProber(prompts: prompts, result: connectedResult)
    let feature = RemoteConnectionsFeatureModel(
        store: store, prober: prober, sessions: prober, locator: NoLocator(), servers: nil
    )
    return (feature, prober)
}

@Suite("RemoteConnections")
struct RemoteConnectionsTests {
    @Test
    func storeKeepsSecretsOutOfPreferencesAndReadsOlderEntries() throws {
        let preferences = MemoryKeyValueStore()
        let secure = MemorySecureStore()
        let store = RemoteConnectionStore(store: preferences, secureStore: secure)
        let connection = RemoteSSHConnection(name: "Tokyo", host: "43.128.251.102", port: 22, user: "root",
                                             authentication: .password, remembersSecret: true)
        try store.save([connection])
        try store.saveSecret("hunter2", for: connection.id)

        #expect(store.load() == [connection])
        #expect(store.secret(for: connection.id) == "hunter2")
        let stored = String(decoding: preferences.data(forKey: "lithe.remote.ssh-connections.v1") ?? Data(), as: UTF8.self)
        #expect(!stored.contains("hunter2"))

        // An entry saved before later fields existed still loads with defaults.
        let older = #"[{"id":"\#(UUID().uuidString)","host":"devbox"}]"#
        preferences.set(Data(older.utf8), forKey: "lithe.remote.ssh-connections.v1")
        let loaded = try #require(store.load().first)
        #expect(loaded.authentication == .auto)
        #expect(loaded.remoteDirectory.isEmpty)
        #expect(loaded.lastKnownHost == nil)
    }

    @Test
    func connectionProblemsAndTargetsFollowTheForm() {
        #expect(RemoteSSHConnection().problem == .missingHost)
        #expect(RemoteSSHConnection(host: "root@box").problem == .invalidHost)
        #expect(RemoteSSHConnection(host: "box", port: 70_000).problem == .invalidPort)
        #expect(RemoteSSHConnection(host: "box", authentication: .privateKey).problem == .missingIdentityFile)
        let target = RemoteSSHConnection(host: " box ", user: "", authentication: .agent, identityFile: "~/.ssh/key").target
        #expect(target.host == "box")
        #expect(target.user == nil)
        // A key path only matters for private-key authentication.
        #expect(target.identityFile == nil)
    }

    // A remembered password answers only the first question that asks for
    // it; the one-time code that follows is the user's to answer.
    @Test @MainActor
    func rememberedSecretAnswersOnlyTheFirstPasswordPrompt() async throws {
        let (feature, prober) = try passwordFeature(
            prompts: [prompt("p1", "root@devbox's password:"), prompt("c1", "Verification code:")],
            savedSecret: "hunter2"
        )
        feature.testSelection()
        #expect(await eventually { !feature.prompts.isEmpty })
        #expect(prober.answers.map(\.answer) == ["hunter2"])
        #expect(feature.prompts.first?.requestId == "c1")

        feature.answerPrompt("123456")
        #expect(await eventually { feature.selectionTestState == .finished(connectedResult) })
        #expect(prober.answers.map(\.id) == ["p1", "c1"])
        #expect(prober.answers.last?.answer == "123456")
    }

    // When the server asks again, the remembered secret was wrong; it must
    // not be sent a second time.
    @Test @MainActor
    func aRepeatedPasswordPromptGoesToTheUser() async throws {
        let (feature, prober) = try passwordFeature(
            prompts: [prompt("p1", "Password:"), prompt("p2", "Password:", attempt: 2)],
            savedSecret: "wrong"
        )
        feature.testSelection()
        #expect(await eventually { feature.prompts.first?.requestId == "p2" })
        #expect(prober.answers.map(\.answer) == ["wrong"])
        feature.answerPrompt(nil)
        #expect(await eventually { feature.selectionTestState == .idle })
        #expect(prober.answers.last?.answer == nil)
    }

    @Test @MainActor
    func savingForgetsSecretsOfRemovedAndNonRememberingConnections() throws {
        let secure = MemorySecureStore()
        let store = RemoteConnectionStore(store: MemoryKeyValueStore(), secureStore: secure)
        let kept = RemoteSSHConnection(host: "a", authentication: .password, remembersSecret: true)
        let removed = RemoteSSHConnection(host: "b", authentication: .password, remembersSecret: true)
        try store.save([kept, removed])
        try store.saveSecret("one", for: kept.id)
        try store.saveSecret("two", for: removed.id)
        let prober = ScriptedProber(prompts: [], result: connectedResult)
        let feature = RemoteConnectionsFeatureModel(
            store: store, prober: prober, sessions: prober, locator: NoLocator(), servers: nil
        )

        feature.selectedID = removed.id
        feature.removeSelection()
        #expect(feature.save())
        #expect(store.secret(for: removed.id) == nil)
        #expect(store.secret(for: kept.id) == "one")

        feature.selectedID = kept.id
        feature.update { $0.remembersSecret = false }
        #expect(feature.save())
        #expect(secure.keys.isEmpty)
    }
}

// MARK: Remote workspace routing

/// A host file system: writes succeed only for the version last read.
private final class FakeTransport: RemoteWorkspaceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (Data, RemoteFileVersion)] = [:]
    var directories: [String: [RemoteDirectoryEntry]] = [:]
    private(set) var expectedVersions: [RemoteFileVersion?] = []
    private var clock: Int64 = 1
    private(set) var mutations: [RemoteFileMutation] = []

    func put(_ text: String, at path: String) {
        lock.withLock {
            clock += 1
            files[path] = (Data(text.utf8), RemoteFileVersion(size: Int64(text.utf8.count), modifiedMs: clock))
        }
    }

    func text(at path: String) -> String? {
        lock.withLock { files[path].map { String(decoding: $0.0, as: UTF8.self) } }
    }

    private(set) var listCount = 0

    func listDirectory(_ path: String, session id: String) throws -> [RemoteDirectoryEntry] {
        lock.withLock { listCount += 1 }
        return directories[path] ?? []
    }

    func readFile(_ path: String, session id: String) throws -> (data: Data, version: RemoteFileVersion) {
        try lock.withLock {
            guard let file = files[path] else { throw RemoteProbeFailure(code: "workspace_not_found", message: "missing") }
            return file
        }
    }

    func writeFile(_ data: Data, to path: String, expected: RemoteFileVersion?, session id: String) throws -> RemoteWriteOutcome {
        lock.withLock {
            expectedVersions.append(expected)
            guard files[path]?.1 == expected else { return .conflict }
            clock += 1
            let version = RemoteFileVersion(size: Int64(data.count), modifiedMs: clock)
            files[path] = (data, version)
            return .saved(version)
        }
    }
}

extension FakeTransport {
    func mutate(_ mutation: RemoteFileMutation, session: String) throws {
        try lock.withLock {
            mutations.append(mutation)
            switch mutation {
            case .createDirectory(let path, _): directories[path] = []
            case .copy(let from, let to), .move(let from, let to):
                guard files[to] == nil else { throw CocoaError(.fileWriteFileExists) }
                guard let source = files[from] else { throw CocoaError(.fileNoSuchFile) }
                files[to] = source
                if case .move = mutation { files.removeValue(forKey: from) }
            case .remove(let path), .trash(let path): files.removeValue(forKey: path)
            }
        }
    }
}

/// Local operations that must not be reached for remote roots.
private struct NoLocalWorkspace: WorkspaceOperations {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private func entry(_ name: String, _ kind: String) -> RemoteDirectoryEntry {
    RemoteDirectoryEntry(name: name, metadata: .init(kind: kind, symlinkTargetKind: nil))
}

@Suite("RemoteConnections directory entries")
struct RemoteDirectoryEntryDecodingTests {
    @Test func readsSizeAndModificationTimeFromTheServerListing() throws {
        let json = #"{"name":"a.txt","metadata":{"kind":"file","size":2048,"modifiedMs":1761400000000,"readonly":false,"mode":420}}"#
        let entry = try JSONDecoder().decode(RemoteDirectoryEntry.self, from: Data(json.utf8))
        #expect(entry.metadata.size == 2048)
        #expect(entry.metadata.modifiedMs == 1_761_400_000_000)
        #expect(!entry.isDirectory)
    }

    @Test func toleratesListingsWithoutSizeOrTime() throws {
        let json = #"{"name":"d","metadata":{"kind":"directory"}}"#
        let entry = try JSONDecoder().decode(RemoteDirectoryEntry.self, from: Data(json.utf8))
        #expect(entry.metadata.size == nil)
        #expect(entry.isDirectory)
    }
}

@Suite("RemoteConnections routing")
struct RemoteWorkspaceRoutingTests {
    private let root = URL(fileURLWithPath: "/tmp/lithe-tests/RemoteWorkspaces/c/h/app", isDirectory: true)

    private func routing() -> (RemoteRoutingFileOperations, RemoteRoutingWorkspaceOperations, FakeTransport, RemoteWorkspaceRegistry) {
        let registry = RemoteWorkspaceRegistry()
        registry.register(RemoteWorkspaceBinding(root: root, remoteRoot: "/srv/app", sessionID: "s", connectionID: UUID()))
        let transport = FakeTransport()
        let files = RemoteRoutingFileOperations(local: MacWorkspaceFileOperations(), registry: registry, transport: transport)
        let tree = RemoteRoutingWorkspaceOperations(local: NoLocalWorkspace(), registry: registry, transport: transport)
        return (files, tree, transport, registry)
    }

    @Test
    func urlsBelowARemoteRootMapToHostPaths() {
        let (_, _, _, registry) = routing()
        #expect(registry.resolve(root.appendingPathComponent("src/main.rs"))?.remotePath == "/srv/app/src/main.rs")
        #expect(registry.resolve(root)?.remotePath == "/srv/app")
        #expect(registry.resolve(URL(fileURLWithPath: "/tmp/lithe-tests/RemoteWorkspaces/c/h/application")) == nil)
    }

    @Test
    func remoteIndexLifecycleReachesTheHostAwareCoreAdapter() {
        final class IndexOperations: WorkspaceOperations, @unchecked Sendable {
            var calls: [String] = []
            func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }
            func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
            func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
            func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) { calls.append("warm:" + rootURL.path) }
            func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: FileVisibilityRules) {
                calls.append("update:" + changedPaths.joined(separator: ","))
            }
            func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) { calls.append("invalidate:" + rootURL.path) }
        }
        let (_, _, transport, registry) = routing()
        let core = IndexOperations()
        let tree = RemoteRoutingWorkspaceOperations(local: core, registry: registry, transport: transport)
        let rules = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        tree.warmSearchIndex(at: root, visibilityRules: rules)
        tree.updateSearchIndex(at: root, changedPaths: ["src/main.rs"], visibilityRules: rules)
        tree.invalidateSearchIndex(at: root, visibilityRules: rules)
        #expect(core.calls == ["warm:" + root.path, "update:src/main.rs", "invalidate:" + root.path])
    }

    // Saving names the version that was read; a file changed on the host in
    // between is reported as a conflict with its current content.
    @Test
    func savesAreCheckedAgainstTheVersionThatWasRead() throws {
        let (files, _, transport, _) = routing()
        transport.put("one", at: "/srv/app/a.txt")
        let url = root.appendingPathComponent("a.txt")
        let read = try #require(try files.readDocumentDetails(from: url, encoding: nil))
        #expect(read.text == "one")

        let saved = try files.writeDocumentText("two", to: url, expectedContent: nil, encoding: .utf8, expectedIdentity: read.identity)
        guard case .saved(let identity) = saved else { Issue.record("expected a save, got \(saved)"); return }
        #expect(transport.text(at: "/srv/app/a.txt") == "two")
        #expect(transport.expectedVersions.first??.size == 3)

        transport.put("changed elsewhere", at: "/srv/app/a.txt")
        let conflict = try files.writeDocumentText("three", to: url, expectedContent: nil, encoding: .utf8, expectedIdentity: identity)
        guard case .conflict(let content, _) = conflict else { Issue.record("expected a conflict, got \(conflict)"); return }
        #expect(content == "changed elsewhere")
        #expect(transport.text(at: "/srv/app/a.txt") == "changed elsewhere")
    }

    @Test
    func theTreeListsFoldersFirstAndHidesConfiguredNames() throws {
        let (_, tree, transport, _) = routing()
        transport.directories["/srv/app"] = [entry("b.txt", "file"), entry("src", "directory"), entry(".git", "directory"), entry("A.md", "file")]
        let rules = FileVisibilityRules(hiddenDirectoryNames: [".git"], hiddenFilePatterns: [])
        let snapshot = try #require(tree.snapshot(at: root, visibilityRules: rules))
        #expect(snapshot.root.children?.map(\.url.lastPathComponent) == ["src", "A.md", "b.txt"])
        #expect(snapshot.root.children?.first?.children == nil)
    }

    // Two files with equal bytes have different versions; saving the first
    // must not send the second one's version to the host.
    @Test
    func equalContentInTwoFilesKeepsSeparateVersions() throws {
        let (files, _, transport, _) = routing()
        transport.put("same", at: "/srv/app/a.txt")
        transport.put("same", at: "/srv/app/b.txt")
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        let readA = try #require(try files.readDocumentDetails(from: a, encoding: nil))
        _ = try files.readDocumentDetails(from: b, encoding: nil)
        let saved = try files.writeDocumentText("edited", to: a, expectedContent: nil, encoding: .utf8, expectedIdentity: readA.identity)
        guard case .saved = saved else { Issue.record("expected a save, got \(saved)"); return }
        #expect(transport.text(at: "/srv/app/a.txt") == "edited")
    }

    @Test
    func existenceAndKindComeFromTheHostListing() {
        let (files, _, transport, _) = routing()
        transport.directories["/srv/app"] = [entry("src", "directory"), entry("a.txt", "file")]
        #expect(files.fileExists(at: root))
        #expect(files.isDirectory(at: root))
        #expect(files.fileExists(at: root.appendingPathComponent("src")))
        #expect(files.isDirectory(at: root.appendingPathComponent("src")))
        #expect(files.fileExists(at: root.appendingPathComponent("a.txt")))
        #expect(!files.isDirectory(at: root.appendingPathComponent("a.txt")))
        #expect(!files.fileExists(at: root.appendingPathComponent("missing.txt")))
    }

    @Test
    func creatingRemoteFilesAndSavingNewDocumentsNeverOverwritesExistingContent() throws {
        let (files, tree, transport, _) = routing()
        let url = root.appendingPathComponent("new.txt")
        try files.createFile(at: url)
        #expect(transport.text(at: "/srv/app/new.txt") == "")
        #expect(throws: CocoaError.self) { try files.createFile(at: url) }
        try files.writeText("x", to: url)
        #expect(transport.text(at: "/srv/app/new.txt") == "x")
        #expect(tree.writeFile("tree", at: root, relativePath: "tree.txt"))
        let saved = try files.writeDocumentText("new", to: root.appendingPathComponent("doc.txt"), expectedContent: nil)
        if case .saved = saved {} else { Issue.record("New document was not created") }
        let conflict = try files.writeDocumentText("overwrite", to: url, expectedContent: nil)
        if case .conflict = conflict {} else { Issue.record("Existing file was overwritten") }
        #expect(transport.text(at: "/srv/app/new.txt") == "x")
    }

    @Test
    func treeMutationsUseHostPathsAndRejectMixedHostsAndRootRemoval() throws {
        let (files, _, transport, registry) = routing()
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        let c = root.appendingPathComponent("c.txt")
        transport.put("content", at: "/srv/app/a.txt")
        try files.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: false)
        try files.copyItem(at: a, to: b)
        #expect(throws: CocoaError.self) { try files.copyItem(at: a, to: b) }
        try files.moveItem(at: b, to: c)
        try files.trashItem(at: c)
        try files.removeItem(at: a)
        #expect(transport.text(at: "/srv/app/a.txt") == nil)
        #expect(transport.text(at: "/srv/app/c.txt") == nil)
        #expect(transport.mutations.last == .remove(path: "/srv/app/a.txt"))
        #expect(transport.mutations.contains(.trash(path: "/srv/app/c.txt")))
        #expect(throws: CocoaError.self) { try files.removeItem(at: root) }
        #expect(throws: CocoaError.self) { try files.moveItem(at: a, to: URL(fileURLWithPath: "/tmp/local-target")) }
        let other = URL(fileURLWithPath: "/tmp/lithe-tests/other")
        registry.register(RemoteWorkspaceBinding(root: other, remoteRoot: "/other", sessionID: "other-host", connectionID: UUID()))
        #expect(throws: CocoaError.self) { try files.copyItem(at: a, to: other.appendingPathComponent("a")) }
    }

    @Test
    func placeholderFoldersNeverCollapseOntoTheirParent() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-roots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let id = UUID()
        let root = try MacRemoteWorkspaceRoots.prepare(in: support, connection: id, remotePath: "/srv/app/..")
        #expect(root.lastPathComponent == "root")
    }

    @Test
    func nonPublicAddressesAreNeverLookedUp() {
        for address in ["10.0.0.1", "::ffff:192.168.1.5", "::", "0.0.0.0", "198.18.0.1", "224.0.0.1", "fd00::1", "ff02::1"] {
            #expect(MacRemoteHostLocator.isPrivate(address), "\(address)")
        }
        #expect(!MacRemoteHostLocator.isPrivate("8.8.8.8"))
    }

    @Test
    func repeatedExistenceChecksShareOneListing() {
        let (files, _, transport, _) = routing()
        transport.directories["/srv/app"] = [entry("a.txt", "file")]
        for _ in 0..<5 { _ = files.fileExists(at: root.appendingPathComponent("a.txt")) }
        #expect(transport.listCount == 1)
    }

    // A lost connection is announced once, however many requests fail.
    @Test
    func aLostConnectionIsReportedOnce() {
        let (_, _, _, registry) = routing()
        let closed = ClosedTransport()
        let watching = ConnectionWatchingTransport(base: closed, registry: registry)
        var announced = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .remoteWorkspaceConnectionLost, object: nil, queue: nil
        ) { _ in announced += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<3 { #expect(throws: RemoteProbeFailure.self) { try watching.listDirectory("/srv/app", session: "s") } }
        #expect(announced == 1)
    }
}

private struct ClosedTransport: RemoteWorkspaceTransport {
    func listDirectory(_ path: String, session id: String) throws -> [RemoteDirectoryEntry] {
        throw RemoteProbeFailure(code: ConnectionWatchingTransport.closedCode, message: "closed")
    }
    func readFile(_ path: String, session id: String) throws -> (data: Data, version: RemoteFileVersion) {
        throw RemoteProbeFailure(code: ConnectionWatchingTransport.closedCode, message: "closed")
    }
    func writeFile(_ data: Data, to path: String, expected: RemoteFileVersion?, session id: String) throws -> RemoteWriteOutcome {
        throw RemoteProbeFailure(code: ConnectionWatchingTransport.closedCode, message: "closed")
    }
}
