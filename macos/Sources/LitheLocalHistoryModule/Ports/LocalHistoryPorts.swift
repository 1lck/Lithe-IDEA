import Foundation

public struct LocalHistoryVisibilityRules: Hashable, Sendable {
    public let hiddenDirectoryNames: [String]
    public let hiddenFilePatterns: [String]
    /// Files the user keeps out of local history only; the project tree still shows them.
    public let ignorePatterns: [String]
    public let ignoreRegexes: [String]
    public init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String],
                ignorePatterns: [String] = [], ignoreRegexes: [String] = []) {
        self.hiddenDirectoryNames = hiddenDirectoryNames
        self.hiddenFilePatterns = hiddenFilePatterns
        self.ignorePatterns = ignorePatterns
        self.ignoreRegexes = ignoreRegexes
    }
}

/// Allocated bytes of one project's local history and the cap eviction keeps.
public struct LocalHistoryUsage: Equatable, Sendable {
    public let usedBytes: Int64
    public let limitBytes: Int64
    public init(usedBytes: Int64, limitBytes: Int64) {
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
    }
}

/// Which rule keeps a sample path out of local history.
public enum LocalHistoryIgnoreMatch: Equatable, Sendable {
    /// Hidden from the project tree, so never recorded.
    case hidden
    /// Inside a generated folder: no baseline is taken, but edits are still recorded.
    case baselineExcluded(directory: String)
    case pattern(index: Int)
    case regex(index: Int)
}

/// Settings feedback for ignore rules: rejected regexes by list position and the sample-path result.
public struct LocalHistoryIgnorePreview: Equatable, Sendable {
    public let regexErrors: [Int: String]
    public let baselineExcludedDirectoryNames: [String]
    public let matched: LocalHistoryIgnoreMatch?
    public init(regexErrors: [Int: String], baselineExcludedDirectoryNames: [String], matched: LocalHistoryIgnoreMatch?) {
        self.regexErrors = regexErrors
        self.baselineExcludedDirectoryNames = baselineExcludedDirectoryNames
        self.matched = matched
    }
}

public struct LocalHistoryEntryPayload: Sendable {
    public let id: String
    public let timestamp: Int64
    public let relativePath: String
    public let reason: String
    public let contentPath: String
    public let byteCount: Int

    public init(id: String, timestamp: Int64, relativePath: String, reason: String, contentPath: String, byteCount: Int) {
        self.id = id
        self.timestamp = timestamp
        self.relativePath = relativePath
        self.reason = reason
        self.contentPath = contentPath
        self.byteCount = byteCount
    }
}

public protocol LocalHistoryOperations: Sendable {
    func record(at workspaceURL: URL, storageURL: URL, relativePath: String, reason: LocalHistoryReason, content: String?, pruneExpired: Bool, visibilityRules: LocalHistoryVisibilityRules) -> LocalHistoryEntryPayload?
    func entries(at workspaceURL: URL, storageURL: URL, relativePath: String?, visibilityRules: LocalHistoryVisibilityRules) -> [LocalHistoryEntryPayload]?
    func content(at storageURL: URL, contentPath: String) -> String?
    func relocate(at storageURL: URL, sourcePath: String, destinationPath: String) -> Bool
    func usage(at storageURL: URL) -> LocalHistoryUsage?
    func clear(at storageURL: URL) -> Bool
    func ignorePreview(path: String?, ignorePatterns: [String], ignoreRegexes: [String]) -> LocalHistoryIgnorePreview?
}

public protocol LocalHistoryWorkspaceAccess: Sendable {
    func fileExists(at url: URL) -> Bool
    func readFile(at workspaceURL: URL, relativePath: String) -> String?
    func writeFile(_ text: String, at workspaceURL: URL, relativePath: String) -> Bool
}

public protocol LocalHistoryStorage: Sendable {
    func applicationSupportDirectory() -> URL
}

public struct LocalHistoryDocumentSnapshot: Sendable {
    public let id: UUID
    public let url: URL
    public let text: String
    public init(id: UUID, url: URL, text: String) { self.id = id; self.url = url; self.text = text }
}
