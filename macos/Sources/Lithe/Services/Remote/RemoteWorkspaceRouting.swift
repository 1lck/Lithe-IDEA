import CryptoKit
import Foundation
import LitheCoreContracts

// Note: 远程工作区按根目录路由见 .agents/notes/implemented/architecture/2026-10-24-remote-workspace-routing.md

/// A remote folder open as a workspace. Its root is an empty local
/// placeholder directory, so the workbench keeps working with file URLs;
/// everything below the root is read and written on the host.
struct RemoteWorkspaceBinding: Sendable {
    /// Standardized placeholder root on this Mac.
    let root: URL
    /// Absolute folder on the host.
    let remoteRoot: String
    let sessionID: String
    let connectionID: UUID

    /// Virtual sibling namespace for host paths outside the opened folder,
    /// including parent repositories and canonical symlink targets. This must
    /// match Rust's Host::host_paths_root; no files are materialized here.
    var hostPathsRoot: URL {
        root.standardizedFileURL.appendingPathExtension("lithe-remote-host")
    }

    func localURL(forRemotePath path: String) -> URL {
        if path == remoteRoot { return root }
        let prefix = remoteRoot.hasSuffix("/") ? remoteRoot : remoteRoot + "/"
        if path.hasPrefix(prefix) {
            return root.appendingPathComponent(String(path.dropFirst(prefix.count))).standardizedFileURL
        }
        return hostPathsRoot.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
    }
}

extension Notification.Name {
    /// Posted once when the connection of an open remote workspace is lost.
    /// `userInfo` holds `RemoteConnectionLoss.userInfoKey`.
    static let remoteWorkspaceConnectionLost = Notification.Name("LitheRemoteWorkspaceConnectionLost")
}

/// What a window needs to offer reconnecting a lost remote workspace.
struct RemoteConnectionLoss: Sendable {
    static let userInfoKey = "loss"
    let root: URL
    let remoteRoot: String
    let connectionID: UUID
}

/// Which local roots are remote workspaces. Shared by every window; the
/// adapters below ask it for each URL they are given.
final class RemoteWorkspaceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [String: RemoteWorkspaceBinding] = [:]
    private var lostSessions: Set<String> = []

    func register(_ binding: RemoteWorkspaceBinding) {
        lock.withLock { bindings[binding.root.standardizedFileURL.path] = binding }
    }

    func unregister(root: URL) -> RemoteWorkspaceBinding? {
        lock.withLock { bindings.removeValue(forKey: root.standardizedFileURL.path) }
    }

    func binding(forRoot root: URL) -> RemoteWorkspaceBinding? {
        lock.withLock { bindings[root.standardizedFileURL.path] }
    }

    /// The binding whose root contains `url` and the matching host path.
    func resolve(_ url: URL) -> (binding: RemoteWorkspaceBinding, remotePath: String)? {
        let path = url.standardizedFileURL.path
        return lock.withLock {
            for (root, binding) in bindings.sorted(by: { $0.key.count > $1.key.count }) {
                let hostRoot = binding.hostPathsRoot.path
                if path == hostRoot { return (binding, "/") }
                if path.hasPrefix(hostRoot + "/") {
                    return (binding, String(path.dropFirst(hostRoot.count)))
                }
                if path == root { return (binding, binding.remoteRoot) }
                let prefix = root.hasSuffix("/") ? root : root + "/"
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                let base = binding.remoteRoot.hasSuffix("/") ? String(binding.remoteRoot.dropLast()) : binding.remoteRoot
                return (binding, base + "/" + relative)
            }
            return nil
        }
    }

    func contains(_ url: URL) -> Bool { resolve(url) != nil }

    /// The binding of `sessionID`, the first time that session is reported
    /// lost; later reports return nil so one loss is announced once.
    func markLost(sessionID: String) -> RemoteWorkspaceBinding? {
        lock.withLock {
            guard let binding = bindings.values.first(where: { $0.sessionID == sessionID }),
                  lostSessions.insert(sessionID).inserted else { return nil }
            return binding
        }
    }
}

/// Reports a lost connection to the window that shows the workspace, so it
/// can offer to reconnect, and passes every other result through.
struct ConnectionWatchingTransport: RemoteWorkspaceTransport {
    /// Stable Core code of a closed or lost connection.
    static let closedCode = "connection_closed"

    let base: any RemoteWorkspaceTransport
    let registry: RemoteWorkspaceRegistry

    func listDirectory(_ path: String, session id: String) throws -> [RemoteDirectoryEntry] {
        try watching(id) { try base.listDirectory(path, session: id) }
    }

    func readFile(_ path: String, session id: String) throws -> (data: Data, version: RemoteFileVersion) {
        try watching(id) { try base.readFile(path, session: id) }
    }

    func writeFile(
        _ data: Data, to path: String, expected: RemoteFileVersion?, session id: String
    ) throws -> RemoteWriteOutcome {
        try watching(id) { try base.writeFile(data, to: path, expected: expected, session: id) }
    }

    func mutate(_ mutation: RemoteFileMutation, session: String) throws {
        try watching(session) { try base.mutate(mutation, session: session) }
    }

    func watch(root: String, session: String, onEvent: @escaping @Sendable (RemoteWatchEvent) -> Void) async throws {
        do {
            try await base.watch(root: root, session: session, onEvent: onEvent)
        } catch {
            try watching(session) { throw error }
        }
    }

    private func watching<Value>(_ id: String, _ work: () throws -> Value) throws -> Value {
        do {
            return try work()
        } catch let failure as RemoteProbeFailure where failure.code == Self.closedCode {
            if let binding = registry.markLost(sessionID: id) {
                let loss = RemoteConnectionLoss(
                    root: binding.root, remoteRoot: binding.remoteRoot, connectionID: binding.connectionID
                )
                NotificationCenter.default.post(
                    name: .remoteWorkspaceConnectionLost, object: nil,
                    userInfo: [RemoteConnectionLoss.userInfoKey: loss]
                )
            }
            throw failure
        }
    }
}

/// Project tree and plain file access: remote roots are listed on the host,
/// all other roots go to the local operations unchanged.
struct RemoteRoutingWorkspaceOperations: WorkspaceOperations {
    let local: any WorkspaceOperations
    let registry: RemoteWorkspaceRegistry
    let transport: any RemoteWorkspaceTransport

    func invalidateDirectoryListings() { local.invalidateDirectoryListings() }

    func configureIndexing(at rootURL: URL, policy: WorkspaceIndexingPolicy, refresh: Bool) throws -> WorkspaceIndexingStatus {
        guard registry.binding(forRoot: rootURL) == nil else {
            // Remote indexing is not supported by the current transport. Never
            // configure the local placeholder as if it were the remote project.
            var status = WorkspaceIndexingStatus()
            status.supportsExclusions = false
            return status
        }
        return try local.configureIndexing(at: rootURL, policy: policy, refresh: refresh)
    }

    func releaseIndexing(at rootURL: URL, revision: UInt64) {
        guard registry.binding(forRoot: rootURL) == nil else { return }
        local.releaseIndexing(at: rootURL, revision: revision)
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        guard let binding = registry.binding(forRoot: rootURL) else {
            return local.snapshot(at: rootURL, visibilityRules: visibilityRules)
        }
        let root = binding.root
        guard let children = try? rows(of: root, at: root, binding: binding, rules: visibilityRules) else {
            return nil
        }
        return WorkspaceSnapshot(
            root: FileNode(url: root, isDirectory: true, children: children),
            files: children.filter { !$0.isDirectory }.map(\.url)
        )
    }

    func childRows(of rows: [FileNode], at rootURL: URL, visibilityRules: FileVisibilityRules) -> [String: [FileNode]]? {
        guard let binding = registry.binding(forRoot: rootURL) else {
            return local.childRows(of: rows, at: rootURL, visibilityRules: visibilityRules)
        }
        var listed: [String: [FileNode]] = [:]
        for row in rows where row.isDirectory {
            // A folder that disappeared on the host is left out, like a
            // local one.
            if let children = try? self.rows(of: row.url, at: binding.root, binding: binding, rules: visibilityRules) {
                listed[row.url.standardizedFileURL.path] = children
            }
        }
        return listed
    }

    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {
        local.warmSearchIndex(at: rootURL, visibilityRules: visibilityRules)
    }

    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: FileVisibilityRules) {
        local.updateSearchIndex(at: rootURL, changedPaths: changedPaths, visibilityRules: visibilityRules)
    }

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {
        local.invalidateSearchIndex(at: rootURL, visibilityRules: visibilityRules)
    }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        let url = rootURL.appendingPathComponent(relativePath)
        guard let (binding, path) = registry.resolve(url) else {
            return local.readFile(at: rootURL, relativePath: relativePath)
        }
        guard let content = try? transport.readFile(path, session: binding.sessionID) else { return nil }
        return String(data: content.data, encoding: .utf8)
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        let url = rootURL.appendingPathComponent(relativePath)
        guard let (binding, path) = registry.resolve(url) else {
            return local.writeFile(text, at: rootURL, relativePath: relativePath)
        }
        do {
            let expected: RemoteFileVersion?
            do { expected = try transport.readFile(path, session: binding.sessionID).version }
            catch let failure as RemoteProbeFailure where failure.code == "workspace_not_found" { expected = nil }
            if case .saved = try transport.writeFile(Data(text.utf8), to: path, expected: expected, session: binding.sessionID) {
                return true
            }
        } catch { return false }
        return false
    }

    /// One level of a remote directory as tree rows: folders unloaded until
    /// expanded, hidden names filtered with the workspace's own rules.
    private func rows(
        of directory: URL, at root: URL, binding: RemoteWorkspaceBinding, rules: FileVisibilityRules
    ) throws -> [FileNode] {
        guard let (_, path) = registry.resolve(directory) else { return [] }
        return try transport.listDirectory(path, session: binding.sessionID)
            .map { entry in
                let url = directory.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
                return FileNode(url: url, isDirectory: entry.isDirectory, children: nil)
            }
            .filter { !rules.isHidden($0.url, relativeTo: root, isDirectory: $0.isDirectory) }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.url.lastPathComponent.localizedStandardCompare(right.url.lastPathComponent) == .orderedAscending
            }
    }
}

/// Editor documents: remote files are read and saved on the host with the
/// same identity and conflict rules as local ones; local files are passed
/// through unchanged.
///
/// A document identity is the SHA-256 of the bytes that were read, as for
/// local files. The host compares versions (size and modification time), so
/// each read remembers its version per session, path and identity: equal
/// bytes in two files, or on two hosts, never share a version.
final class RemoteRoutingFileOperations: WorkspaceFileOperations, @unchecked Sendable {
    private let local: any WorkspaceFileOperations
    private let registry: RemoteWorkspaceRegistry
    private let transport: any RemoteWorkspaceTransport
    private let lock = NSLock()
    /// Version read for each session, path and identity, bounded to recently
    /// opened files.
    private var versions: [String: RemoteFileVersion] = [:]
    private var versionOrder: [String] = []
    private static let rememberedVersions = 512
    /// Parent listings used to answer existence checks, so a burst of
    /// `fileExists` calls costs one round trip. Mutations and observed external
    /// changes drop them; the short lifetime also covers inactive observers.
    private var listings: [String: (entries: [RemoteDirectoryEntry], at: Date)] = [:]
    private static let listingLifetime: TimeInterval = 3

    init(local: any WorkspaceFileOperations, registry: RemoteWorkspaceRegistry, transport: any RemoteWorkspaceTransport) {
        self.local = local
        self.registry = registry
        self.transport = transport
    }

    var supportsDocumentEncoding: Bool { local.supportsDocumentEncoding }

    // MARK: Remote reads and writes

    private func remoteRead(_ url: URL) throws -> (text: String, encoding: DocumentEncoding, identity: String)? {
        guard let (binding, path) = registry.resolve(url) else { return nil }
        let content: (data: Data, version: RemoteFileVersion)
        do {
            content = try transport.readFile(path, session: binding.sessionID)
        } catch let failure as RemoteProbeFailure where failure.code == "workspace_not_found" {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var bytes = content.data
        var encoding = DocumentEncoding.utf8
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
            encoding = .utf8Bom
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let identity = Self.identity(of: content.data)
        remember(content.version, for: versionKey(binding, path, identity))
        return (text, encoding, identity)
    }

    private func remoteWrite(
        _ text: String, to url: URL, encoding: DocumentEncoding, expectedIdentity: String?
    ) throws -> EncodedDocumentWriteResult {
        guard let (binding, path) = registry.resolve(url) else { throw CocoaError(.fileNoSuchFile) }
        guard encoding == .utf8 || encoding == .utf8Bom else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        var data = Data(text.utf8)
        if encoding == .utf8Bom { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        var expected = expectedIdentity.flatMap { version(for: versionKey(binding, path, $0)) }
        if let expectedIdentity, expected == nil {
            // Opened before this session: compare the current bytes.
            let current = try transport.readFile(path, session: binding.sessionID)
            guard Self.identity(of: current.data) == expectedIdentity else {
                return .conflict(content: String(data: current.data, encoding: .utf8), identity: Self.identity(of: current.data))
            }
            expected = current.version
        }
        lock.withLock { listings.removeAll() }
        switch try transport.writeFile(data, to: path, expected: expected, session: binding.sessionID) {
        case .saved(let version):
            let identity = Self.identity(of: data)
            remember(version, for: versionKey(binding, path, identity))
            return .saved(identity: identity)
        case .conflict:
            let current = try? transport.readFile(path, session: binding.sessionID)
            return .conflict(
                content: current.flatMap { String(data: $0.data, encoding: .utf8) },
                identity: current.map { Self.identity(of: $0.data) }
            )
        }
    }

    private static func identity(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func versionKey(_ binding: RemoteWorkspaceBinding, _ path: String, _ identity: String) -> String {
        "\(binding.sessionID)\n\(path)\n\(identity)"
    }

    private func remember(_ version: RemoteFileVersion, for identity: String) {
        lock.withLock {
            if versions.updateValue(version, forKey: identity) == nil { versionOrder.append(identity) }
            while versionOrder.count > Self.rememberedVersions {
                versions.removeValue(forKey: versionOrder.removeFirst())
            }
        }
    }

    private func version(for identity: String) -> RemoteFileVersion? {
        lock.withLock { versions[identity] }
    }

    private func remoteOnly(_ url: URL) throws {
        if registry.contains(url) { throw CocoaError(.featureUnsupported) }
    }

    // MARK: WorkspaceFileOperations

    /// Whether the host has `url`, and if so whether it is a folder. The
    /// root is a folder; anything else is looked up in its parent's listing.
    private func remoteKind(of url: URL) -> (exists: Bool, isDirectory: Bool)? {
        guard let (binding, _) = registry.resolve(url) else { return nil }
        if url.standardizedFileURL == binding.root.standardizedFileURL { return (true, true) }
        guard let (_, parentPath) = registry.resolve(url.deletingLastPathComponent()),
              let entries = cachedListing(parentPath, session: binding.sessionID),
              let entry = entries.first(where: { $0.name == url.lastPathComponent })
        else { return (false, false) }
        return (true, entry.isDirectory)
    }

    private func cachedListing(_ path: String, session: String) -> [RemoteDirectoryEntry]? {
        let key = "\(session)\n\(path)"
        if let hit = lock.withLock({ listings[key] }), Date().timeIntervalSince(hit.at) < Self.listingLifetime {
            return hit.entries
        }
        guard let entries = try? transport.listDirectory(path, session: session) else { return nil }
        lock.withLock { listings[key] = (entries, Date()) }
        return entries
    }

    func fileExists(at url: URL) -> Bool {
        remoteKind(of: url)?.exists ?? local.fileExists(at: url)
    }

    func isDirectory(at url: URL) -> Bool {
        remoteKind(of: url)?.isDirectory ?? local.isDirectory(at: url)
    }

    func createFile(at url: URL) throws {
        if let (binding, path) = registry.resolve(url) {
            guard url.standardizedFileURL != binding.root.standardizedFileURL else { throw CocoaError(.fileWriteFileExists) }
            lock.withLock { listings.removeAll() }
            guard case .saved = try transport.writeFile(Data(), to: path, expected: nil, session: binding.sessionID) else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        try local.createFile(at: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        if let (binding, path) = registry.resolve(url) {
            try mutate(.createDirectory(path: path, recursive: withIntermediateDirectories), binding: binding)
            return
        }
        try local.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        if try transfer(sourceURL, destinationURL, copying: true) { return }
        try local.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if try transfer(sourceURL, destinationURL, copying: false) { return }
        try local.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        if let (binding, path) = registry.resolve(url) {
            try requireNonRoot(url, binding: binding)
            try mutate(.remove(path: path), binding: binding)
            return
        }
        try local.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        if let (binding, path) = registry.resolve(url) {
            try requireNonRoot(url, binding: binding)
            try mutate(.trash(path: path), binding: binding)
            return
        }
        try local.trashItem(at: url)
    }

    func trashDocument(at url: URL, expectedIdentity: String) throws -> DocumentTrashResult {
        try remoteOnly(url)
        return try local.trashDocument(at: url, expectedIdentity: expectedIdentity)
    }

    func writeText(_ text: String, to url: URL) throws {
        guard registry.contains(url) else { return try local.writeText(text, to: url) }
        let identity: String?
        do { identity = try remoteRead(url)?.identity }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { identity = nil }
        if case .conflict = try remoteWrite(text, to: url, encoding: .utf8, expectedIdentity: identity) {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    func readText(from url: URL) throws -> String {
        if let read = try remoteRead(url) { return read.text }
        return try local.readText(from: url)
    }

    func observeDocuments(at urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) -> any DocumentFileObservation {
        let localObservation = local.observeDocuments(at: urls.filter { !registry.contains($0) }, onChange: onChange)
        let groups = Dictionary(grouping: urls.filter { registry.contains($0) }) { registry.resolve($0)!.binding.root }
        let observations = groups.compactMap { root, documents -> RemoteDirectoryObservation? in
            guard let binding = registry.binding(forRoot: root) else { return nil }
            let observation = RemoteDirectoryObservation(
                configuration: DirectoryWatchConfiguration(workspaceRoot: root, gitContext: nil),
                visibilityRules: FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: []),
                binding: binding, registry: registry, transport: transport
            ) { [weak self] batch in
                self?.lock.withLock { self?.listings.removeAll() }
                let affected = batch.requiresFullRescan ? documents : documents.filter { document in
                    batch.workspacePaths.contains { path in document.path == path || document.path.hasPrefix(path + "/") }
                }
                if !affected.isEmpty { onChange(affected) }
            }
            observation.start()
            return observation
        }
        return RemoteDocumentObservations(local: localObservation, remote: observations)
    }

    private func requireNonRoot(_ url: URL, binding: RemoteWorkspaceBinding) throws {
        guard url.standardizedFileURL != binding.root.standardizedFileURL else { throw CocoaError(.fileWriteNoPermission) }
    }

    private func mutate(_ mutation: RemoteFileMutation, binding: RemoteWorkspaceBinding) throws {
        defer { lock.withLock { listings.removeAll() } }
        try transport.mutate(mutation, session: binding.sessionID)
    }

    private func transfer(_ source: URL, _ destination: URL, copying: Bool) throws -> Bool {
        let from = registry.resolve(source)
        let to = registry.resolve(destination)
        guard from != nil || to != nil else { return false }
        guard let from, let to, from.binding.sessionID == to.binding.sessionID else {
            throw CocoaError(.featureUnsupported)
        }
        try requireNonRoot(source, binding: from.binding)
        try requireNonRoot(destination, binding: to.binding)
        try mutate(copying ? .copy(from: from.remotePath, to: to.remotePath) : .move(from: from.remotePath, to: to.remotePath), binding: from.binding)
        return true
    }

    func readDocumentText(from url: URL) throws -> String? {
        if registry.contains(url) { return try remoteRead(url)?.text }
        return try local.readDocumentText(from: url)
    }

    func readDocumentTextAsync(from url: URL) async throws -> String? {
        if registry.contains(url) { return try await background { try self.remoteRead(url)?.text } }
        return try await local.readDocumentTextAsync(from: url)
    }

    func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?) async throws -> DocumentWriteResult {
        if registry.contains(url) { return try await background { try self.writeDocumentText(text, to: url, expectedContent: expectedContent) } }
        return try await local.writeDocumentTextAsync(text, to: url, expectedContent: expectedContent)
    }

    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?) throws -> DocumentWriteResult {
        guard registry.contains(url) else { return try local.writeDocumentText(text, to: url, expectedContent: expectedContent) }
        let identity = expectedContent.map { Self.identity(of: Data($0.utf8)) }
        switch try remoteWrite(text, to: url, encoding: .utf8, expectedIdentity: identity) {
        case .saved: return .saved
        case .conflict(let content, _): return .conflict(content)
        }
    }

    func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
        guard registry.contains(url) else { return try local.readDocumentDetails(from: url, encoding: encoding) }
        return try remoteDetails(url, encoding: encoding)
    }

    func readDocumentDetailsAsync(from url: URL, encoding: DocumentEncoding?) async throws -> DocumentReadDetails? {
        guard registry.contains(url) else { return try await local.readDocumentDetailsAsync(from: url, encoding: encoding) }
        return try await background { try self.remoteDetails(url, encoding: encoding) }
    }

    func readDocumentChangeAsync(from url: URL, encoding: DocumentEncoding?, knownIdentity: String?) async throws -> DocumentChangeReadResult {
        guard registry.contains(url) else {
            return try await local.readDocumentChangeAsync(from: url, encoding: encoding, knownIdentity: knownIdentity)
        }
        guard let details = try await background({ try self.remoteDetails(url, encoding: encoding) }) else { return .missing }
        if let knownIdentity, details.identity == knownIdentity { return .unchanged }
        return .changed(details)
    }

    func writeDocumentText(
        _ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding, expectedIdentity: String?
    ) throws -> EncodedDocumentWriteResult {
        guard registry.contains(url) else {
            return try local.writeDocumentText(
                text, to: url, expectedContent: expectedContent, encoding: encoding, expectedIdentity: expectedIdentity
            )
        }
        return try remoteWrite(
            text, to: url, encoding: encoding,
            expectedIdentity: expectedIdentity ?? expectedContent.map { Self.identity(of: Data($0.utf8)) }
        )
    }

    func writeDocumentTextAsync(
        _ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding, expectedIdentity: String?
    ) async throws -> EncodedDocumentWriteResult {
        guard registry.contains(url) else {
            return try await local.writeDocumentTextAsync(
                text, to: url, expectedContent: expectedContent, encoding: encoding, expectedIdentity: expectedIdentity
            )
        }
        return try await background {
            try self.writeDocumentText(
                text, to: url, expectedContent: expectedContent, encoding: encoding, expectedIdentity: expectedIdentity
            )
        }
    }

    func writeDocumentTextAsync(
        _ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding, expectedIdentity: String?,
        hardLinkAuthorization: DocumentHardLinkAuthorization
    ) async throws -> EncodedDocumentWriteResult {
        // Consent names a local native object, never a remote transport write.
        try remoteOnly(url)
        return try await local.writeDocumentTextAsync(text, to: url, expectedContent: expectedContent,
            encoding: encoding, expectedIdentity: expectedIdentity, hardLinkAuthorization: hardLinkAuthorization)
    }

    private func remoteDetails(_ url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
        guard encoding == nil || encoding == .utf8 || encoding == .utf8Bom else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        guard let read = try remoteRead(url) else { return nil }
        return DocumentReadDetails(text: read.text, encoding: read.encoding, identity: read.identity)
    }

    /// Runs a blocking network call off the caller's executor.
    private func background<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
