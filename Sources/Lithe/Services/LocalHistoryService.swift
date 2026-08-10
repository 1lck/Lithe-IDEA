import Foundation

actor LocalHistoryService {
    private let workspaceURL: URL
    private var visibilityRules: FileVisibilityRules
    private let storageURL: URL
    private let operations: any LocalHistoryOperations

    init(
        workspaceURL: URL,
        visibilityRules: FileVisibilityRules = .default,
        storage: any FileStorage,
        operations: any LocalHistoryOperations
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.visibilityRules = visibilityRules
        self.operations = operations
        let applicationSupport = storage.applicationSupportDirectory()
        storageURL = applicationSupport
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("LocalHistory", isDirectory: true)
            .appendingPathComponent(Self.stableIdentifier(for: workspaceURL.path), isDirectory: true)
    }

    func updateVisibilityRules(_ rules: FileVisibilityRules) {
        visibilityRules = rules
    }

    func seed(files: [URL]) async {
        for fileURL in files where !Task.isCancelled {
            _ = try? recordFile(at: fileURL, reason: .projectBaseline, pruneExpired: false)
        }
    }

    @discardableResult
    func recordFile(
        at fileURL: URL,
        reason: LocalHistoryReason,
        pruneExpired: Bool = true
    ) throws -> LocalHistoryEntry? {
        guard let relativePath = relativePath(for: fileURL) else { return nil }
        return try record(
            relativePath: relativePath,
            reason: reason,
            content: nil,
            pruneExpired: pruneExpired
        )
    }

    @discardableResult
    func record(text: String, for fileURL: URL, reason: LocalHistoryReason) throws -> LocalHistoryEntry? {
        guard let relativePath = relativePath(for: fileURL) else { return nil }
        return try record(relativePath: relativePath, reason: reason, content: text, pruneExpired: true)
    }

    func entries(for fileURL: URL) throws -> [LocalHistoryEntry] {
        guard let relativePath = relativePath(for: fileURL) else { return [] }
        guard let values = operations.entries(
            at: workspaceURL,
            storageURL: storageURL,
            relativePath: relativePath,
            visibilityRules: visibilityRules
        ) else { throw LocalHistoryError.coreUnavailable }
        return values.compactMap { makeEntry($0) }
    }

    func allEntries() throws -> [LocalHistoryEntry] {
        guard let values = operations.entries(
            at: workspaceURL,
            storageURL: storageURL,
            relativePath: nil,
            visibilityRules: visibilityRules
        ) else { throw LocalHistoryError.coreUnavailable }
        return values.compactMap { makeEntry($0) }
    }

    func content(for entry: LocalHistoryEntry) throws -> String {
        guard let contentPath = relativeStoragePath(for: entry.contentURL),
              let value = operations.content(at: storageURL, contentPath: contentPath) else {
            throw LocalHistoryError.contentUnavailable
        }
        return value
    }

    func relocateHistory(from sourceURL: URL, to destinationURL: URL) throws {
        guard let sourcePath = relativePath(for: sourceURL),
              let destinationPath = relativePath(for: destinationURL),
              operations.relocate(
                  at: storageURL,
                  sourcePath: sourcePath,
                  destinationPath: destinationPath
              ) else {
            throw LocalHistoryError.coreUnavailable
        }
    }

    private func record(
        relativePath: String,
        reason: LocalHistoryReason,
        content: String?,
        pruneExpired: Bool
    ) throws -> LocalHistoryEntry? {
        guard let value = operations.record(
            at: workspaceURL,
            storageURL: storageURL,
            relativePath: relativePath,
            reason: reason,
            content: content,
            pruneExpired: pruneExpired,
            visibilityRules: visibilityRules
        ) else { return nil }
        return makeEntry(value)
    }

    private func makeEntry(_ value: RustCoreBridge.HistoryEntryPayload) -> LocalHistoryEntry? {
        guard let id = UUID(uuidString: value.id) else { return nil }
        return LocalHistoryEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(value.timestamp)),
            relativePath: value.relativePath,
            reason: LocalHistoryReason(rawValue: value.reason) ?? .saved,
            contentURL: storageURL.appendingPathComponent(value.contentPath),
            byteCount: value.byteCount
        )
    }

    private func relativePath(for fileURL: URL) -> String? {
        let rootPath = workspaceURL.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func relativeStoragePath(for fileURL: URL) -> String? {
        let rootPath = storageURL.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private enum LocalHistoryError: Error {
    case coreUnavailable
    case contentUnavailable
}
