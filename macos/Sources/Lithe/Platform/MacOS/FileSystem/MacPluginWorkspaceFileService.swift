import CryptoKit
import Darwin
import Foundation
import LitheCoreContracts
import LitheSearchModule

/// macOS implementation of ``PluginWorkspaceFileAccess``.
///
/// - Roots: only `.local` authorities whose URL is not a remote placeholder
///   are served. Each root ID tracks its newest generation; requests with an
///   older or closed generation fail with `.staleWorkspace`, and a newer
///   generation releases the watchers of the older one.
/// - Blocking work (descriptor walks, directory reads, file reads and the
///   synchronous Rust search) runs on `workQueue`, never on the caller's
///   executor. A task cancellation returns `.cancelled` at once; the worker
///   stops at its next check (Rust search cannot be interrupted and its late
///   result is dropped). A caller's concurrency slot is returned only when
///   the worker actually ends, so cancelled work still counts against the
///   budget.
/// - Results carry resource IDs (`rootID` + relative path) only.
final class MacPluginWorkspaceFileService: PluginWorkspaceFileAccess, @unchecked Sendable {
    private let budgets: PluginWorkspaceFileBudgets
    private let searchOperations: any SearchOperations
    private let isRemoteWorkspaceRoot: @Sendable (URL) -> Bool
    private let watchHub: MacPluginWorkspaceWatchHub
    private let workQueue = DispatchQueue(
        label: "app.lithe.plugin-workspace-files",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var activeOperations: [PluginWorkspaceCaller: Int] = [:]
    private var newestGenerations: [String: UInt64] = [:]
    private var closedGenerations: [String: UInt64] = [:]

    /// - Parameter isRemoteWorkspaceRoot: whether a URL is a local placeholder
    ///   of a remote root (production: `MacRemoteWorkspaceRoots` registry).
    ///   Such a root is rejected even if the caller labelled it `.local`.
    init(
        budgets: PluginWorkspaceFileBudgets = .default,
        searchOperations: any SearchOperations,
        watcherFactory: any DirectoryWatcherFactory,
        isRemoteWorkspaceRoot: @escaping @Sendable (URL) -> Bool,
        makeWatchDelivery: @escaping @Sendable () -> any PluginWorkspaceWatchDelivery = {
            MacPluginWorkspaceWatchQueueDelivery()
        }
    ) {
        self.budgets = budgets
        self.searchOperations = searchOperations
        self.isRemoteWorkspaceRoot = isRemoteWorkspaceRoot
        watchHub = MacPluginWorkspaceWatchHub(
            budgets: budgets,
            watcherFactory: watcherFactory,
            makeDelivery: makeWatchDelivery
        )
    }

    var activeWatchSubscriptionCount: Int { watchHub.activeSubscriptionCount }
    var activeWatchStreamCount: Int { watchHub.activeStreamCount }

    // MARK: - API-06

    func readDirectory(
        _ path: String,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        cursor: String?,
        limit: Int?
    ) async throws -> PluginWorkspaceDirectoryPage {
        try admit(root)
        let components = try MacWorkspaceSecurePath.components(of: path)
        let directoryPath = components.joined(separator: "/")
        let pageSize = Self.clamp(limit, default: budgets.defaultDirectoryPageSize, maximum: budgets.maximumDirectoryPageSize)
        let after = try cursor.map { try DirectoryCursor.decode($0, root: root, directory: directoryPath) }
        let budgets = budgets
        return try await perform(for: caller) { cancellation in
            try Self.listDirectory(
                components: components,
                root: root,
                after: after,
                pageSize: pageSize,
                budgets: budgets,
                cancellation: cancellation
            )
        }
    }

    func stat(
        _ path: String,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller
    ) async throws -> PluginWorkspaceFileStat {
        try admit(root)
        let components = try MacWorkspaceSecurePath.components(of: path)
        return try await perform(for: caller) { _ in
            let rootDescriptor = try MacWorkspaceSecurePath.openRoot(root.url)
            defer { Darwin.close(rootDescriptor) }
            let status: Darwin.stat
            if let name = components.last {
                let parent = try MacWorkspaceSecurePath.openDirectory(components.dropLast(), below: rootDescriptor)
                defer { Darwin.close(parent) }
                status = try MacWorkspaceSecurePath.status(of: name, in: parent)
            } else {
                var rootStatus = Darwin.stat()
                guard fstat(rootDescriptor, &rootStatus) == 0 else { throw MacWorkspaceSecurePath.map(errno) }
                status = rootStatus
            }
            let modified = status.st_mtimespec
            return PluginWorkspaceFileStat(
                resource: PluginWorkspaceResource(rootID: root.id, path: components.joined(separator: "/")),
                kind: MacWorkspaceSecurePath.kind(of: status),
                size: UInt64(max(0, status.st_size)),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000)
            )
        }
    }

    func readFile(
        _ path: String,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        maximumBytes: Int?
    ) async throws -> PluginWorkspaceFileContents {
        try admit(root)
        let components = try MacWorkspaceSecurePath.components(of: path)
        guard let name = components.last else { throw PluginWorkspaceFileError.notRegularFile }
        let limit = Self.clamp(maximumBytes, default: budgets.defaultReadBytes, maximum: budgets.maximumReadBytes)
        return try await perform(for: caller) { cancellation in
            let rootDescriptor = try MacWorkspaceSecurePath.openRoot(root.url)
            defer { Darwin.close(rootDescriptor) }
            let parent = try MacWorkspaceSecurePath.openDirectory(components.dropLast(), below: rootDescriptor)
            defer { Darwin.close(parent) }
            let file = try MacWorkspaceSecurePath.openRegularFile(named: name, in: parent)
            defer { Darwin.close(file.descriptor) }
            let bytes = try Self.readBytes(from: file.descriptor, limit: limit + 1, cancellation: cancellation)
            let isTruncated = bytes.count > limit
            let kept = isTruncated ? Data(bytes.prefix(limit)) : bytes
            return PluginWorkspaceFileContents(
                resource: PluginWorkspaceResource(rootID: root.id, path: components.joined(separator: "/")),
                content: Self.classify(kept, isTruncated: isTruncated),
                byteCount: kept.count,
                isTruncated: isTruncated,
                identity: isTruncated ? nil : MacDocumentEncoding.identity(kept),
                source: .disk
            )
        }
    }

    // MARK: - API-07

    func watch(
        _ path: String,
        recursive: Bool,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        onEvent: @escaping @Sendable (PluginWorkspaceWatchEvent) -> Void
    ) throws -> any PluginWorkspaceWatchSubscription {
        try admit(root)
        // The path need not exist yet; FSEvents never reports through links,
        // so a link component simply produces no events.
        let basePath = try MacWorkspaceSecurePath.components(of: path).joined(separator: "/")
        return try watchHub.subscribe(
            basePath: basePath,
            recursive: recursive,
            root: root,
            caller: caller,
            onEvent: onEvent
        )
    }

    // MARK: - API-08

    func findFiles(
        _ query: PluginWorkspaceFindFilesQuery,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        cursor: String?,
        limit: Int?
    ) async throws -> PluginWorkspaceSearchPage<PluginWorkspaceFileMatch> {
        try admit(root)
        let fingerprint = Self.fingerprint(["files", query.query, query.fileMask])
        let offset = try SearchCursor.decode(cursor, root: root, fingerprint: fingerprint)
        let pageSize = Self.clamp(limit, default: budgets.defaultSearchPageSize, maximum: budgets.maximumSearchPageSize)
        guard !query.query.isEmpty else { return Self.emptyPage() }
        let searchOperations = searchOperations
        let cap = budgets.searchResultCap
        return try await perform(for: caller) { cancellation in
            guard let results = searchOperations.searchEverywhere(
                at: root.url,
                query: query.query,
                options: ProjectSearchOptions(fileMask: query.fileMask),
                visibilityRules: root.visibilityRules.searchRules,
                includeGeneratedFileNames: false,
                kinds: [.file]
            ) else { throw PluginWorkspaceFileError.searchUnavailable }
            try cancellation.check()
            let prefixes = MacPluginWorkspacePaths.rootPrefixes(of: root.url)
            let matches = results.fileMatches.compactMap { result -> PluginWorkspaceFileMatch? in
                MacPluginWorkspacePaths.relativePath(of: result.url.path, rootPrefixes: prefixes)
                    .flatMap { $0.isEmpty ? nil : PluginWorkspaceFileMatch(resource: PluginWorkspaceResource(rootID: root.id, path: $0)) }
            }
            return Self.page(
                matches,
                offset: offset,
                pageSize: pageSize,
                isTruncated: results.fileMatches.count >= cap,
                root: root,
                fingerprint: fingerprint
            )
        }
    }

    func findText(
        _ query: PluginWorkspaceFindTextQuery,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        cursor: String?,
        limit: Int?
    ) async throws -> PluginWorkspaceSearchPage<PluginWorkspaceTextMatch> {
        try admit(root)
        let fingerprint = Self.fingerprint([
            "text", query.pattern, query.fileMask,
            "\(query.caseSensitive)", "\(query.wholeWords)", "\(query.regularExpression)",
        ])
        let offset = try SearchCursor.decode(cursor, root: root, fingerprint: fingerprint)
        let pageSize = Self.clamp(limit, default: budgets.defaultSearchPageSize, maximum: budgets.maximumSearchPageSize)
        guard !query.pattern.isEmpty else { return Self.emptyPage() }
        let searchOperations = searchOperations
        let cap = budgets.searchResultCap
        return try await perform(for: caller) { cancellation in
            guard let results = searchOperations.search(
                at: root.url,
                query: query.pattern,
                options: ProjectSearchOptions(
                    caseSensitive: query.caseSensitive,
                    wholeWords: query.wholeWords,
                    regularExpression: query.regularExpression,
                    fileMask: query.fileMask
                ),
                visibilityRules: root.visibilityRules.searchRules
            ) else { throw PluginWorkspaceFileError.searchUnavailable }
            try cancellation.check()
            let prefixes = MacPluginWorkspacePaths.rootPrefixes(of: root.url)
            let matches = results.filter { $0.kind == .content }.compactMap { result -> PluginWorkspaceTextMatch? in
                guard let path = MacPluginWorkspacePaths.relativePath(of: result.url.path, rootPrefixes: prefixes),
                      !path.isEmpty else { return nil }
                return PluginWorkspaceTextMatch(
                    resource: PluginWorkspaceResource(rootID: root.id, path: path),
                    line: result.line ?? 1,
                    preview: result.preview
                )
            }
            return Self.page(
                matches,
                offset: offset,
                pageSize: pageSize,
                isTruncated: results.count >= cap,
                root: root,
                fingerprint: fingerprint
            )
        }
    }

    // MARK: - Ownership

    func releaseResources(of caller: PluginWorkspaceCaller) {
        watchHub.releaseResources(of: caller)
    }

    func closeWorkspace(rootID: String, generation: UInt64) {
        lock.withLock {
            closedGenerations[rootID] = max(closedGenerations[rootID] ?? 0, generation)
        }
        watchHub.closeGenerations(rootID: rootID, through: generation)
    }

    // MARK: - Roots and admission

    private func admit(_ root: PluginWorkspaceRoot) throws {
        guard case .local = root.authority else { throw PluginWorkspaceFileError.unsupportedAuthority }
        guard !root.id.isEmpty, root.url.isFileURL else { throw PluginWorkspaceFileError.invalidRoot }
        guard !isRemoteWorkspaceRoot(root.url) else { throw PluginWorkspaceFileError.unsupportedAuthority }
        let supersededGeneration: UInt64? = try lock.withLock {
            if let closed = closedGenerations[root.id], root.generation <= closed {
                throw PluginWorkspaceFileError.staleWorkspace
            }
            guard let newest = newestGenerations[root.id] else {
                newestGenerations[root.id] = root.generation
                return nil
            }
            if root.generation < newest { throw PluginWorkspaceFileError.staleWorkspace }
            guard root.generation > newest else { return nil }
            newestGenerations[root.id] = root.generation
            return root.generation - 1
        }
        if let supersededGeneration {
            watchHub.closeGenerations(rootID: root.id, through: supersededGeneration)
        }
    }

    private func perform<Value: Sendable>(
        for caller: PluginWorkspaceCaller,
        _ work: @escaping @Sendable (OperationCancellation) throws -> Value
    ) async throws -> Value {
        let maximum = budgets.maximumConcurrentOperationsPerCaller
        try lock.withLock {
            let active = activeOperations[caller, default: 0]
            guard active < maximum else { throw PluginWorkspaceFileError.limitExceeded(.concurrentOperations) }
            activeOperations[caller] = active + 1
        }
        let cancellation = OperationCancellation()
        let gate = OneShotContinuation<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                gate.install(continuation)
                workQueue.async { [self] in
                    let result = Result<Value, Error> { try work(cancellation) }
                    finishOperation(for: caller)
                    gate.resume(with: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
            gate.resume(with: .failure(PluginWorkspaceFileError.cancelled))
        }
    }

    private func finishOperation(for caller: PluginWorkspaceCaller) {
        lock.withLock {
            let remaining = activeOperations[caller, default: 1] - 1
            activeOperations[caller] = remaining > 0 ? remaining : nil
        }
    }

    private static func clamp(_ requested: Int?, default defaultValue: Int, maximum: Int) -> Int {
        guard let requested else { return defaultValue }
        return min(max(requested, 1), maximum)
    }

    // MARK: - Directory listing

    private struct SortKey {
        let isDirectory: Bool
        let name: String
        let utf16: [UInt16]

        init(isDirectory: Bool, name: String) {
            self.isDirectory = isDirectory
            self.name = name
            utf16 = Array(name.utf16)
        }

        /// Project-view sibling order made total by a byte tie-break, so a
        /// cursor names exactly one position.
        func precedes(_ other: SortKey) -> Bool {
            if isDirectory != other.isDirectory { return isDirectory }
            let order = NaturalNameOrder.compare(utf16, other.utf16, ignoreCase: true, likeFileNames: true)
            if order != 0 { return order < 0 }
            return name.utf8.lexicographicallyPrecedes(other.name.utf8)
        }
    }

    private struct ListedEntry {
        let key: SortKey
        let kind: PluginWorkspaceEntryKind
    }

    private static func listDirectory(
        components: [String],
        root: PluginWorkspaceRoot,
        after: DirectoryCursor?,
        pageSize: Int,
        budgets: PluginWorkspaceFileBudgets,
        cancellation: OperationCancellation
    ) throws -> PluginWorkspaceDirectoryPage {
        let rootDescriptor = try MacWorkspaceSecurePath.openRoot(root.url)
        defer { Darwin.close(rootDescriptor) }
        let directory = try MacWorkspaceSecurePath.openDirectory(components[...], below: rootDescriptor)
        defer { Darwin.close(directory) }

        let rootURL = root.url.standardizedFileURL
        let directoryPath = components.joined(separator: "/")
        func relativePath(_ name: String) -> String {
            directoryPath.isEmpty ? name : directoryPath + "/" + name
        }

        var seen: Set<String> = []
        var entries: [ListedEntry] = []
        try readNames(of: directory, maximum: budgets.maximumDirectoryScanEntries, cancellation: cancellation) { rawName, type in
            let name = rawName.precomposedStringWithCanonicalMapping
            guard seen.insert(name).inserted else { return }
            let kind: PluginWorkspaceEntryKind
            switch Int32(type) {
            case DT_DIR: kind = .directory
            case DT_REG: kind = .file
            case DT_LNK: kind = .symbolicLink
            case DT_UNKNOWN:
                guard let status = try? MacWorkspaceSecurePath.status(of: rawName, in: directory) else { return }
                kind = MacWorkspaceSecurePath.kind(of: status)
            default: kind = .other
            }
            // Same omissions as the Project view: links, then hidden rules.
            guard kind != .symbolicLink else { return }
            let isDirectory = kind == .directory
            guard !root.visibilityRules.isHidden(
                rootURL.appendingPathComponent(relativePath(name)),
                relativeTo: rootURL,
                isDirectory: isDirectory
            ) else { return }
            entries.append(ListedEntry(key: SortKey(isDirectory: isDirectory, name: name), kind: kind))
        }
        try cancellation.check()
        entries.sort { $0.key.precedes($1.key) }

        let startKey = after.map { SortKey(isDirectory: $0.isDirectory, name: $0.name) }
        var index = startKey.map { key in entries.firstIndex { key.precedes($0.key) } ?? entries.endIndex } ?? 0
        let snapshotBuilder = FileSystemWorkspaceSnapshotBuilder()
        var page: [PluginWorkspaceDirectoryEntry] = []
        while index < entries.endIndex, page.count < pageSize {
            try cancellation.check()
            let entry = entries[index]
            index += 1
            let path = relativePath(entry.key.name)
            if entry.kind == .directory,
               snapshotBuilder.isNestedLinkedWorktree(rootURL.appendingPathComponent(path, isDirectory: true)) {
                continue
            }
            page.append(PluginWorkspaceDirectoryEntry(
                name: entry.key.name,
                resource: PluginWorkspaceResource(rootID: root.id, path: path),
                kind: entry.kind
            ))
        }
        // The cursor is the last examined key (a returned entry or a skipped
        // nested worktree after it), so the next page starts right after it.
        let nextCursor = index < entries.endIndex
            ? DirectoryCursor(
                root: root.id,
                generation: root.generation,
                directory: directoryPath,
                isDirectory: entries[index - 1].key.isDirectory,
                name: entries[index - 1].key.name
            ).encoded()
            : nil
        return PluginWorkspaceDirectoryPage(
            directory: PluginWorkspaceResource(rootID: root.id, path: directoryPath),
            entries: page,
            nextCursor: nextCursor
        )
    }

    /// Reads raw entry names with `readdir` from a duplicate of `directory`.
    /// Names that are not valid UTF-8 cannot form a resource ID and are
    /// skipped (APFS stores UTF-8 only).
    private static func readNames(
        of directory: Int32,
        maximum: Int,
        cancellation: OperationCancellation,
        _ body: (String, UInt8) throws -> Void
    ) throws {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw MacWorkspaceSecurePath.map(errno) }
        guard let stream = fdopendir(duplicate) else {
            let error = errno
            Darwin.close(duplicate)
            throw MacWorkspaceSecurePath.map(error)
        }
        defer { closedir(stream) }
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw MacWorkspaceSecurePath.map(errno) }
                return
            }
            let nameCapacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(validatingCString: $0) }
            }
            guard let name, name != ".", name != ".." else { continue }
            count += 1
            if count > maximum { throw PluginWorkspaceFileError.limitExceeded(.directoryEntries) }
            if count % 1_024 == 0 { try cancellation.check() }
            try body(name, entry.pointee.d_type)
        }
    }

    // MARK: - File reading

    private static let readChunkSize = 64 * 1024

    private static func readBytes(from descriptor: Int32, limit: Int, cancellation: OperationCancellation) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: readChunkSize)
        while data.count < limit {
            try cancellation.check()
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                throw MacWorkspaceSecurePath.map(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Text when the editor's strict detection decodes the bytes and the text
    /// passes the editor's plain-text policy; otherwise binary. A truncated
    /// prefix may end inside a character, so up to three trailing bytes are
    /// dropped from the decoded text (never from `byteCount`).
    static func classify(_ bytes: Data, isTruncated: Bool) -> PluginWorkspaceFileContent {
        guard !bytes.isEmpty else { return .text("", encoding: DocumentEncoding.utf8.rawValue) }
        let maximumTrim = isTruncated ? min(3, bytes.count - 1) : 0
        // A UTF-8 prefix cut inside a character is not valid UTF-8 and would
        // otherwise fall through to GB18030 detection, so the shortest trim
        // that yields UTF-8 is preferred.
        let utf8Trim = (0...maximumTrim).first { String(data: Data(bytes.dropLast($0)), encoding: .utf8) != nil }
        let trims = utf8Trim.map { [$0] } ?? Array(0...maximumTrim)
        for trim in trims {
            guard let details = try? MacDocumentEncoding.decode(Data(bytes.dropLast(trim)), encoding: nil) else { continue }
            guard WorkspaceTextFilePolicy.isPlainText(details.text) else { return .binary(bytes) }
            return .text(details.text, encoding: details.encoding.rawValue)
        }
        return .binary(bytes)
    }

    // MARK: - Search pages

    private static func emptyPage<Match: Sendable>() -> PluginWorkspaceSearchPage<Match> {
        PluginWorkspaceSearchPage(matches: [], nextCursor: nil, isTruncated: false, source: .disk)
    }

    private static func page<Match: Sendable>(
        _ matches: [Match],
        offset: Int,
        pageSize: Int,
        isTruncated: Bool,
        root: PluginWorkspaceRoot,
        fingerprint: String
    ) -> PluginWorkspaceSearchPage<Match> {
        let start = min(offset, matches.count)
        let end = min(start + pageSize, matches.count)
        let nextCursor = end < matches.count
            ? SearchCursor(root: root.id, generation: root.generation, fingerprint: fingerprint, offset: end).encoded()
            : nil
        return PluginWorkspaceSearchPage(
            matches: Array(matches[start..<end]),
            nextCursor: nextCursor,
            isTruncated: isTruncated,
            source: .disk
        )
    }

    private static func fingerprint(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Cursors

/// Opaque cursors are base64 JSON. They are not secrets: a forged cursor can
/// only name a position inside the same directory or result list, and every
/// field is checked against the request.
private enum CursorCoding {
    static let maximumLength = 4_096

    static func encode<Value: Encodable>(_ value: Value) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return data.base64EncodedString()
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from cursor: String) throws -> Value {
        guard cursor.utf8.count <= maximumLength,
              let data = Data(base64Encoded: cursor),
              let value = try? JSONDecoder().decode(type, from: data)
        else { throw PluginWorkspaceFileError.invalidCursor }
        return value
    }
}

private struct DirectoryCursor: Codable {
    static let version = 1

    var v = DirectoryCursor.version
    let root: String
    let generation: UInt64
    let directory: String
    let isDirectory: Bool
    let name: String

    init(root: String, generation: UInt64, directory: String, isDirectory: Bool, name: String) {
        self.root = root
        self.generation = generation
        self.directory = directory
        self.isDirectory = isDirectory
        self.name = name
    }

    func encoded() -> String { CursorCoding.encode(self) }

    static func decode(_ cursor: String, root: PluginWorkspaceRoot, directory: String) throws -> DirectoryCursor {
        let value = try CursorCoding.decode(DirectoryCursor.self, from: cursor)
        guard value.v == version, value.root == root.id, value.generation == root.generation,
              value.directory == directory, !value.name.isEmpty
        else { throw PluginWorkspaceFileError.invalidCursor }
        return value
    }
}

private struct SearchCursor: Codable {
    static let version = 1

    var v = SearchCursor.version
    let root: String
    let generation: UInt64
    let fingerprint: String
    let offset: Int

    init(root: String, generation: UInt64, fingerprint: String, offset: Int) {
        self.root = root
        self.generation = generation
        self.fingerprint = fingerprint
        self.offset = offset
    }

    func encoded() -> String { CursorCoding.encode(self) }

    /// The offset a cursor resumes at; `nil` starts at 0.
    static func decode(_ cursor: String?, root: PluginWorkspaceRoot, fingerprint: String) throws -> Int {
        guard let cursor else { return 0 }
        let value = try CursorCoding.decode(SearchCursor.self, from: cursor)
        guard value.v == version, value.root == root.id, value.generation == root.generation,
              value.fingerprint == fingerprint, value.offset > 0
        else { throw PluginWorkspaceFileError.invalidCursor }
        return value.offset
    }
}

// MARK: - Cancellation

/// Set from the task's cancellation handler, polled by the worker.
private final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    func check() throws {
        if lock.withLock({ cancelled }) { throw PluginWorkspaceFileError.cancelled }
    }
}

/// Resumes a continuation exactly once, whichever of the worker result and the
/// cancellation arrives first, including a cancellation that arrives before
/// the continuation exists.
private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var early: Result<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let early: Result<Value, Error>? = lock.withLock {
            if let early = self.early {
                finished = true
                return early
            }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !finished else { return nil }
            guard let continuation = self.continuation else {
                if early == nil { early = result }
                return nil
            }
            self.continuation = nil
            finished = true
            return continuation
        }
        continuation?.resume(with: result)
    }
}
