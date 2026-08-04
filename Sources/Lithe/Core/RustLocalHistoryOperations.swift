import Foundation

protocol LocalHistoryOperations: Sendable {
    func record(
        at workspaceURL: URL,
        storageURL: URL,
        relativePath: String,
        reason: LocalHistoryReason,
        content: String?,
        pruneExpired: Bool,
        visibilityRules: FileVisibilityRules
    ) -> RustCoreBridge.HistoryEntryPayload?

    func entries(
        at workspaceURL: URL,
        storageURL: URL,
        relativePath: String?,
        visibilityRules: FileVisibilityRules
    ) -> [RustCoreBridge.HistoryEntryPayload]?

    func content(
        at storageURL: URL,
        contentPath: String
    ) -> String?

    func relocate(
        at storageURL: URL,
        sourcePath: String,
        destinationPath: String
    ) -> Bool
}

struct RustLocalHistoryOperations: LocalHistoryOperations, Sendable {
    let core: RustCoreBridge

    func record(
        at workspaceURL: URL,
        storageURL: URL,
        relativePath: String,
        reason: LocalHistoryReason,
        content: String?,
        pruneExpired: Bool,
        visibilityRules: FileVisibilityRules
    ) -> RustCoreBridge.HistoryEntryPayload? {
        core.historyRecord(
            at: workspaceURL,
            storageURL: storageURL,
            relativePath: relativePath,
            reason: reason.rawValue,
            content: content,
            pruneExpired: pruneExpired,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )
    }

    func entries(
        at workspaceURL: URL,
        storageURL: URL,
        relativePath: String?,
        visibilityRules: FileVisibilityRules
    ) -> [RustCoreBridge.HistoryEntryPayload]? {
        core.historyEntries(
            at: workspaceURL,
            storageURL: storageURL,
            relativePath: relativePath,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns
        )?.entries
    }

    func content(at storageURL: URL, contentPath: String) -> String? {
        core.historyContent(storageURL: storageURL, contentPath: contentPath)?.text
    }

    func relocate(at storageURL: URL, sourcePath: String, destinationPath: String) -> Bool {
        core.historyRelocate(
            storageURL: storageURL,
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
    }
}
