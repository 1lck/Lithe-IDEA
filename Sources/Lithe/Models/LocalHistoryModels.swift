import Foundation

struct LocalHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let relativePath: String
    let reason: LocalHistoryReason
    let contentURL: URL
    let byteCount: Int
}

enum LocalHistoryReason: String, Codable, Sendable {
    case projectBaseline
    case saved
    case externalChange
    case beforeRename
    case beforeDelete
    case beforeBatchReplace
    case unsavedDiscard
    case restored

    var title: String {
        switch self {
        case .projectBaseline: "Project opened"
        case .saved: "File saved"
        case .externalChange: "External change"
        case .beforeRename: "Before rename"
        case .beforeDelete: "Before deletion"
        case .beforeBatchReplace: "Before project replacement"
        case .unsavedDiscard: "Discarded editor changes"
        case .restored: "Before restore"
        }
    }
}

struct LocalHistoryRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
}

struct ProjectLocalHistoryRequest: Identifiable {
    let id = UUID()
}

enum LocalHistoryDiffBuilder {
    static func rows(old oldText: String, current currentText: String) -> [DiffRow] {
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

        var rows: [DiffRow] = []
        var oldIndex = 0
        var currentIndex = 0
        while oldIndex < oldLines.count || currentIndex < currentLines.count {
            let oldIsRemoved = oldIndex < oldLines.count && removals.contains(oldIndex)
            let currentIsInserted = currentIndex < currentLines.count && insertions.contains(currentIndex)
            if !oldIsRemoved, !currentIsInserted,
               oldIndex < oldLines.count, currentIndex < currentLines.count {
                rows.append(DiffRow(
                    oldLine: oldIndex + 1,
                    newLine: currentIndex + 1,
                    left: oldLines[oldIndex],
                    right: currentLines[currentIndex],
                    kind: .context
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
            let count = max(removed.count, inserted.count)
            if count == 0 {
                if oldIndex < oldLines.count {
                    removals.insert(oldIndex)
                } else if currentIndex < currentLines.count {
                    insertions.insert(currentIndex)
                }
                continue
            }
            for index in 0..<count {
                let left = index < removed.count ? removed[index] : nil
                let right = index < inserted.count ? inserted[index] : nil
                rows.append(DiffRow(
                    oldLine: left?.0,
                    newLine: right?.0,
                    left: left?.1,
                    right: right?.1,
                    kind: left != nil && right != nil ? .changed : (left != nil ? .removal : .addition)
                ))
            }
        }
        return rows
    }

    private static func lines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
