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
    let upstreamShortName: String?

    var id: String { fullName }
}

struct GitStash: Identifiable, Hashable, Sendable {
    let reference: String
    let message: String
    let branch: String?
    let date: String

    var id: String { reference }
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

/// Read-only diff context for a file changed by a historical commit.
struct GitCommitDiffContext: Identifiable, Hashable, Sendable {
    let repositoryRoot: URL
    let commit: GitCommit
    let file: GitCommitFile

    var id: String { "\(commit.hash):\(file.id)" }
    var path: String { file.path }
    var url: URL { repositoryRoot.appendingPathComponent(file.path) }

    var kind: GitChangeKind {
        if file.status.hasPrefix("A") { return .added }
        if file.status.hasPrefix("D") { return .deleted }
        if file.status.hasPrefix("R") { return .moved }
        if file.status.hasPrefix("C") { return .copied }
        return .modified
    }
}

struct GitBlameLine: Identifiable, Hashable, Sendable {
    let line: Int
    let commitHash: String
    let authorName: String
    let date: String

    var id: Int { line }
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
    let hasMore: Bool
}

struct GitChange: Identifiable, Hashable, Sendable {
    let repositoryRoot: URL
    let path: String
    let originalPath: String?
    let indexStatus: Character
    let workTreeStatus: Character

    var id: String { "\(originalPath ?? "")->\(path)" }
    var url: URL { repositoryRoot.appendingPathComponent(path) }
    var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    var hasWorkingTreeChange: Bool { workTreeStatus != " " }
    var isUntracked: Bool { indexStatus == "?" && workTreeStatus == "?" }

    var kind: GitChangeKind {
        if isUntracked || indexStatus == "A" || workTreeStatus == "A" { return .added }
        if indexStatus == "D" || workTreeStatus == "D" { return .deleted }
        if indexStatus == "R" || workTreeStatus == "R" { return .moved }
        if indexStatus == "C" || workTreeStatus == "C" { return .copied }
        return .modified
    }

    var pathspecs: [String] {
        if let originalPath, originalPath != path { return [originalPath, path] }
        return [path]
    }

    var displayStatus: String {
        if isUntracked { return "A" }
        if workTreeStatus != " " { return String(workTreeStatus) }
        return String(indexStatus)
    }
}

enum GitChangeKind: String, Sendable {
    case added
    case modified
    case deleted
    case moved
    case copied

    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .moved: "Moved"
        case .copied: "Copied"
        }
    }

    var symbol: String {
        switch self {
        case .added: "plus"
        case .modified: "pencil"
        case .deleted: "minus"
        case .moved: "arrow.right"
        case .copied: "doc.on.doc"
        }
    }
}

enum GitDiffWhitespaceMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case doNotIgnore
    case ignoreAllWhitespace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doNotIgnore:
            return "Do not ignore"
        case .ignoreAllWhitespace:
            return "Ignore whitespace"
        }
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
    let id: UUID
    let oldLine: Int?
    let newLine: Int?
    let left: String?
    let right: String?
    let kind: DiffRowKind
    let hunkID: String?

    init(
        oldLine: Int?,
        newLine: Int?,
        left: String?,
        right: String?,
        kind: DiffRowKind,
        hunkID: String? = nil
    ) {
        self.id = UUID()
        self.oldLine = oldLine
        self.newLine = newLine
        self.left = left
        self.right = right
        self.kind = kind
        self.hunkID = hunkID
    }
}

struct DiffHunk: Identifiable, Sendable {
    let id: String
    let header: String
    let rows: [DiffRow]
    let patch: String
}

struct DiffDocument: Sendable {
    let rows: [DiffRow]
    let hunks: [DiffHunk]
}

struct DiffHunkRequest: Identifiable {
    let id = UUID()
    let change: GitChange
    let hunk: DiffHunk
}

enum DiffParser {
    private struct Entry {
        let number: Int
        let text: String
    }

    static func parse(_ patch: String) -> [DiffRow] {
        parseDocument(patch).rows
    }

    static func parseDocument(_ patch: String) -> DiffDocument {
        var rows: [DiffRow] = []
        var oldLine = 0
        var newLine = 0
        var removed: [Entry] = []
        var added: [Entry] = []
        var currentHunkID: String?
        var currentHunkHeader = ""
        var currentHunkLines: [String] = []
        var fileHeaderLines: [String] = []
        var hunkRecords: [(id: String, header: String, lines: [String])] = []
        var hunkIndex = 0
        let hasTrailingNewline = patch.hasSuffix("\n")
        var patchLines = patch.components(separatedBy: "\n")
        if hasTrailingNewline {
            patchLines.removeLast()
        }

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
                    kind: kind,
                    hunkID: currentHunkID
                ))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        func finishHunk() {
            guard let hunkID = currentHunkID else { return }
            flushChanges()
            hunkRecords.append((
                id: hunkID,
                header: currentHunkHeader,
                lines: currentHunkLines
            ))
            currentHunkID = nil
            currentHunkHeader = ""
            currentHunkLines.removeAll(keepingCapacity: true)
        }

        for line in patchLines {
            if line.hasPrefix("@@") {
                finishHunk()
                let hunkID = "hunk-\(hunkIndex)"
                hunkIndex += 1
                currentHunkID = hunkID
                currentHunkHeader = line
                currentHunkLines = fileHeaderLines + [line]
                if let ranges = parseHunkHeader(line) {
                    oldLine = ranges.old
                    newLine = ranges.new
                }
                rows.append(DiffRow(
                    oldLine: nil,
                    newLine: nil,
                    left: line,
                    right: line,
                    kind: .information,
                    hunkID: hunkID
                ))
            } else if line.hasPrefix("diff --git"), currentHunkID != nil {
                finishHunk()
                fileHeaderLines = [line]
            } else if currentHunkID == nil {
                fileHeaderLines.append(line)
            } else if line.hasPrefix("-") {
                currentHunkLines.append(line)
                removed.append(Entry(number: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix("+") {
                currentHunkLines.append(line)
                added.append(Entry(number: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix(" ") {
                flushChanges()
                currentHunkLines.append(line)
                let text = String(line.dropFirst())
                rows.append(DiffRow(
                    oldLine: oldLine,
                    newLine: newLine,
                    left: text,
                    right: text,
                    kind: .context,
                    hunkID: currentHunkID
                ))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\ No newline") {
                currentHunkLines.append(line)
            } else {
                currentHunkLines.append(line)
            }
        }
        finishHunk()

        let hunks = hunkRecords.map { record in
            let patchText = record.lines.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
            return DiffHunk(
                id: record.id,
                header: record.header,
                rows: rows.filter { $0.hunkID == record.id },
                patch: patchText
            )
        }
        return DiffDocument(rows: rows, hunks: hunks)
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
