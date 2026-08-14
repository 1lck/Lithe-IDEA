import Foundation
import LitheCoreContracts

public struct LocalHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let relativePath: String
    public let reason: LocalHistoryReason
    public let contentURL: URL
    public let byteCount: Int

    public init(id: UUID, timestamp: Date, relativePath: String, reason: LocalHistoryReason, contentURL: URL, byteCount: Int) {
        self.id = id
        self.timestamp = timestamp
        self.relativePath = relativePath
        self.reason = reason
        self.contentURL = contentURL
        self.byteCount = byteCount
    }
}

public typealias LocalHistoryReason = LitheCoreContracts.LocalHistoryReason

public struct LocalHistoryRequest: Identifiable {
    public let id = UUID()
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
}

public struct ProjectLocalHistoryRequest: Identifiable {
    public let id = UUID()
    public init() {}
}

public enum LocalHistoryDiffBuilder {
    public static func rows(old oldText: String, current currentText: String) -> [LocalHistoryDiffRow] {
        let oldLines = lines(in: oldText)
        let currentLines = lines(in: currentText)
        let difference = currentLines.difference(from: oldLines)
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }

        var rows: [LocalHistoryDiffRow] = []
        var oldIndex = 0
        var currentIndex = 0
        while oldIndex < oldLines.count || currentIndex < currentLines.count {
            let oldIsRemoved = oldIndex < oldLines.count && removals.contains(oldIndex)
            let currentIsInserted = currentIndex < currentLines.count && insertions.contains(currentIndex)
            if !oldIsRemoved, !currentIsInserted,
               oldIndex < oldLines.count, currentIndex < currentLines.count {
                rows.append(LocalHistoryDiffRow(
                    oldLine: oldIndex + 1,
                    newLine: currentIndex + 1,
                    left: oldLines[oldIndex],
                    right: nil,
                    kind: .context,
                    sequence: rows.count
                ))
                oldIndex += 1
                currentIndex += 1
                continue
            }

            var removed: [(Int, String)] = []
            while oldIndex < oldLines.count, removals.contains(oldIndex) {
                removed.append((oldIndex + 1, oldLines[oldIndex]))
                oldIndex += 1
            }
            var inserted: [(Int, String)] = []
            while currentIndex < currentLines.count, insertions.contains(currentIndex) {
                inserted.append((currentIndex + 1, currentLines[currentIndex]))
                currentIndex += 1
            }
            if removed.isEmpty, inserted.isEmpty {
                if oldIndex < oldLines.count {
                    removals.insert(oldIndex)
                } else if currentIndex < currentLines.count {
                    insertions.insert(currentIndex)
                }
                continue
            }
            // Pair by similarity so an unrelated delete and insert do not render
            // as one bogus modification. Shared with the Rust diff path.
            let pairs = LocalHistoryDiffPairing.pairs(
                removed: removed.map(\.1),
                added: inserted.map(\.1)
            )
            for (leftIndex, rightIndex) in pairs {
                let left = leftIndex.map { removed[$0] }
                let right = rightIndex.map { inserted[$0] }
                rows.append(LocalHistoryDiffRow(
                    oldLine: left?.0,
                    newLine: right?.0,
                    left: left?.1,
                    right: right?.1,
                    kind: left != nil && right != nil ? .changed : (left != nil ? .removal : .addition),
                    sequence: rows.count
                ))
            }
        }
        return rows
    }

    private static func lines(in text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
