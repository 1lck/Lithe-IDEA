import Foundation

public struct LocalHistoryVisibilityRules: Hashable, Sendable {
    public let hiddenDirectoryNames: [String]
    public let hiddenFilePatterns: [String]
    /// Files the user keeps out of local history only; the project tree still shows them.
    /// A `!` glob turns off a built-in folder rule the user removed.
    public let ignorePatterns: [String]
    public let ignoreRegexes: [String]
    /// Storage cap for the project; nil keeps Rust Core's 100 MB default.
    public let storageLimitBytes: Int64?
    public init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String],
                ignorePatterns: [String] = [], ignoreRegexes: [String] = [],
                storageLimitBytes: Int64? = nil) {
        self.hiddenDirectoryNames = hiddenDirectoryNames
        self.hiddenFilePatterns = hiddenFilePatterns
        self.ignorePatterns = ignorePatterns
        self.ignoreRegexes = ignoreRegexes
        self.storageLimitBytes = storageLimitBytes
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
    /// The wildcard rule as written, built-in or the user's own.
    case pattern(String)
    case regex(index: Int)
}

/// Settings feedback for ignore rules: rejected regexes by list position and the sample-path result.
public struct LocalHistoryIgnorePreview: Equatable, Sendable {
    public let regexErrors: [Int: String]
    /// The built-in wildcard rules, before the user's changes.
    public let builtInIgnorePatterns: [String]
    public let matched: LocalHistoryIgnoreMatch?
    /// Whether Git ignores the path, shown for comparison; nil outside a repository.
    public let gitIgnored: Bool?
    public init(regexErrors: [Int: String], builtInIgnorePatterns: [String],
                matched: LocalHistoryIgnoreMatch?, gitIgnored: Bool? = nil) {
        self.regexErrors = regexErrors
        self.builtInIgnorePatterns = builtInIgnorePatterns
        self.matched = matched
        self.gitIgnored = gitIgnored
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
    func usage(at storageURL: URL, limitBytes: Int64?) -> LocalHistoryUsage?
    func clear(at storageURL: URL) -> Bool
    func ignorePreview(path: String?, rules: LocalHistoryVisibilityRules, workspaceURL: URL?) -> LocalHistoryIgnorePreview?
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
