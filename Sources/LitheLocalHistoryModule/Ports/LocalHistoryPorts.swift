import Foundation

public struct LocalHistoryVisibilityRules: Hashable, Sendable {
    public let hiddenDirectoryNames: [String]
    public let hiddenFilePatterns: [String]
    public init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String]) {
        self.hiddenDirectoryNames = hiddenDirectoryNames
        self.hiddenFilePatterns = hiddenFilePatterns
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
