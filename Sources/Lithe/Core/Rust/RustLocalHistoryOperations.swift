import Foundation
import LitheLocalHistoryModule

struct RustLocalHistoryOperations: LocalHistoryOperations, Sendable {
    let core: RustCoreBridge

    func record(at workspaceURL: URL, storageURL: URL, relativePath: String, reason: LocalHistoryReason, content: String?, pruneExpired: Bool, visibilityRules: LocalHistoryVisibilityRules) -> LocalHistoryEntryPayload? {
        core.historyRecord(
            at: workspaceURL, storageURL: storageURL, relativePath: relativePath,
            reason: reason.rawValue, content: content, pruneExpired: pruneExpired,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        ).map(Self.makePayload)
    }

    func entries(at workspaceURL: URL, storageURL: URL, relativePath: String?, visibilityRules: LocalHistoryVisibilityRules) -> [LocalHistoryEntryPayload]? {
        core.historyEntries(
            at: workspaceURL, storageURL: storageURL, relativePath: relativePath,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.entries.map(Self.makePayload)
    }

    func content(at storageURL: URL, contentPath: String) -> String? { core.historyContent(storageURL: storageURL, contentPath: contentPath)?.text }
    func relocate(at storageURL: URL, sourcePath: String, destinationPath: String) -> Bool { core.historyRelocate(storageURL: storageURL, sourcePath: sourcePath, destinationPath: destinationPath) }

    private static func makePayload(_ value: RustCoreBridge.HistoryEntryPayload) -> LocalHistoryEntryPayload {
        LocalHistoryEntryPayload(id: value.id, timestamp: value.timestamp, relativePath: value.relativePath, reason: value.reason, contentPath: value.contentPath, byteCount: value.byteCount)
    }
}
