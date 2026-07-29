import Foundation

struct GitSnapshot: Sendable {
    let repositoryRoot: URL
    let branch: String
    let changes: [GitChange]
}

enum GitReferenceKind: String, Sendable {
    case local
    case remote
    case tag
}

struct GitReference: Identifiable, Hashable, Sendable {
    let fullName: String
    let shortName: String
    let kind: GitReferenceKind
    let isCurrent: Bool

    var id: String { fullName }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let parentHashes: [String]
    let authorName: String
    let authorEmail: String
    let date: String
    let subject: String
    let decorations: String

    var id: String { hash }
}

struct GitCommitFile: Identifiable, Hashable, Sendable {
    let status: String
    let path: String

    var id: String { "\(status):\(path)" }
}

struct GitBranchComparisonFile: Identifiable, Hashable, Sendable {
    let status: String
    let path: String

    var id: String { "\(status):\(path)" }
}

struct GitBranchComparison: Identifiable, Sendable {
    let reference: GitReference
    let files: [GitBranchComparisonFile]

    var id: String { reference.id }
}

struct GitHistorySnapshot: Sendable {
    let references: [GitReference]
    let commits: [GitCommit]
}

struct GitChange: Identifiable, Hashable, Sendable {
    let repositoryRoot: URL
    let path: String
    let indexStatus: Character
    let workTreeStatus: Character

    var id: String { path }
    var url: URL { repositoryRoot.appendingPathComponent(path) }
    var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    var hasWorkingTreeChange: Bool { workTreeStatus != " " }
    var isUntracked: Bool { indexStatus == "?" && workTreeStatus == "?" }

    var displayStatus: String {
        if isUntracked { return "A" }
        if workTreeStatus != " " { return String(workTreeStatus) }
        return String(indexStatus)
    }
}

enum DiffRowKind: Sendable, Equatable {
    case context
    case changed
    case addition
    case removal
    case information
}

struct DiffRow: Identifiable, Sendable {
    let id = UUID()
    let oldLine: Int?
    let newLine: Int?
    let left: String?
    let right: String?
    let kind: DiffRowKind
}

enum DiffParser {
    private struct Entry {
        let number: Int
        let text: String
    }

    static func parse(_ patch: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine = 0
        var newLine = 0
        var removed: [Entry] = []
        var added: [Entry] = []

        func flushChanges() {
            let count = max(removed.count, added.count)
            guard count > 0 else { return }
            for index in 0..<count {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                let kind: DiffRowKind
                if left != nil && right != nil {
                    kind = .changed
                } else if left != nil {
                    kind = .removal
                } else {
                    kind = .addition
                }
                rows.append(DiffRow(
                    oldLine: left?.number,
                    newLine: right?.number,
                    left: left?.text,
                    right: right?.text,
                    kind: kind
                ))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@") {
                flushChanges()
                if let ranges = parseHunkHeader(line) {
                    oldLine = ranges.old
                    newLine = ranges.new
                }
                rows.append(DiffRow(oldLine: nil, newLine: nil, left: line, right: line, kind: .information))
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                continue
            } else if line.hasPrefix("-") {
                removed.append(Entry(number: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix("+") {
                added.append(Entry(number: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix(" ") {
                flushChanges()
                let text = String(line.dropFirst())
                rows.append(DiffRow(oldLine: oldLine, newLine: newLine, left: text, right: text, kind: .context))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\ No newline") {
                continue
            }
        }
        flushChanges()
        return rows
    }

    private static func parseHunkHeader(_ header: String) -> (old: Int, new: Int)? {
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header),
              let old = Int(header[oldRange]),
              let new = Int(header[newRange]) else { return nil }
        return (old, new)
    }
}
