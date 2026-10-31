import Foundation
import LitheLocalHistoryModule

struct RustLocalHistoryOperations: LocalHistoryOperations, Sendable {
    let core: RustCoreBridge

    func record(at workspaceURL: URL, storageURL: URL, relativePath: String, reason: LocalHistoryReason, content: String?, pruneExpired: Bool, visibilityRules: LocalHistoryVisibilityRules) -> LocalHistoryEntryPayload? {
        core.historyRecord(
            at: workspaceURL, storageURL: storageURL, relativePath: relativePath,
            reason: reason.rawValue, content: content, pruneExpired: pruneExpired,
            hiddenDirectoryNames: visibilityRules.hiddenDirectoryNames,
            hiddenFilePatterns: visibilityRules.hiddenFilePatterns,
            ignorePatterns: visibilityRules.ignorePatterns,
            ignoreRegexes: visibilityRules.ignoreRegexes,
            baselineExcludedDirectoryNames: visibilityRules.baselineExcludedDirectoryNames,
            storageLimitBytes: visibilityRules.storageLimitBytes
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

    func usage(at storageURL: URL, limitBytes: Int64?) -> LocalHistoryUsage? {
        core.historyUsage(storageURL: storageURL, limitBytes: limitBytes).map { LocalHistoryUsage(usedBytes: $0.usedBytes, limitBytes: $0.limitBytes) }
    }

    func clear(at storageURL: URL) -> Bool { core.historyClear(storageURL: storageURL) }

    func ignorePreview(path: String?, rules: LocalHistoryVisibilityRules, workspaceURL: URL?) -> LocalHistoryIgnorePreview? {
        guard let value = core.historyIgnorePreview(
            path: path,
            ignorePatterns: rules.ignorePatterns,
            ignoreRegexes: rules.ignoreRegexes,
            baselineExcludedDirectoryNames: rules.baselineExcludedDirectoryNames,
            hiddenFilePatterns: rules.hiddenFilePatterns,
            workspaceURL: workspaceURL
        ) else { return nil }
        let matched: LocalHistoryIgnoreMatch? = switch value.matched {
        case nil: nil
        case .hidden: .hidden
        case .baselineExcluded(let directory): .baselineExcluded(directory: directory)
        case .pattern(let index): .pattern(index: index)
        case .regex(let index): .regex(index: index)
        }
        return LocalHistoryIgnorePreview(
            regexErrors: Dictionary(value.regexErrors.map { ($0.index, $0.message) }, uniquingKeysWith: { first, _ in first }),
            builtInBaselineExcludedDirectoryNames: value.builtInBaselineExcludedDirectoryNames,
            matched: matched,
            gitIgnored: value.gitIgnored
        )
    }

    private static func makePayload(_ value: RustCoreBridge.HistoryEntryPayload) -> LocalHistoryEntryPayload {
        LocalHistoryEntryPayload(id: value.id, timestamp: value.timestamp, relativePath: value.relativePath, reason: value.reason, contentPath: value.contentPath, byteCount: value.byteCount)
    }
}
