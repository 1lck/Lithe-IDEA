import Foundation

struct GitWatchContext: Equatable, Sendable {
    let repositoryRoot: URL
    let gitDirectory: URL
    let gitCommonDirectory: URL
}

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

/// Structured information returned when `git stash pop` keeps the entry because
/// restoring it created unresolved conflicts. The stash is intentionally not
/// dropped so the user can finish recovery without losing the original patch.
struct GitStashRestoreConflict: Hashable, Sendable {
    let stashReference: String
    let conflictedPaths: [String]
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

struct GitCommitFileTreeNode: Identifiable, Sendable {
    let path: String
    let name: String
    let directories: [GitCommitFileTreeNode]
    let files: [GitCommitFile]

    var id: String { path.isEmpty ? "." : path }

    var fileCount: Int {
        files.count + directories.reduce(0) { $0 + $1.fileCount }
    }

    static func build(from files: [GitCommitFile], rootName: String) -> GitCommitFileTreeNode {
        let root = MutableGitCommitFileTreeNode(name: rootName, path: "")

        for file in files {
            let components = file.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else {
                root.files.append(file)
                continue
            }

            var node = root
            var pathComponents: [String] = []
            for component in components.dropLast() {
                pathComponents.append(component)
                let path = pathComponents.joined(separator: "/")
                if node.directories[component] == nil {
                    node.directories[component] = MutableGitCommitFileTreeNode(
                        name: component,
                        path: path
                    )
                }
                node = node.directories[component]!
            }
            node.files.append(file)
        }

        return makeNode(from: root, isRoot: true)
    }

    private static func makeNode(
        from node: MutableGitCommitFileTreeNode,
        isRoot: Bool = false
    ) -> GitCommitFileTreeNode {
        let result = GitCommitFileTreeNode(
            path: node.path,
            name: node.name,
            directories: node.directories.values
                .map { makeNode(from: $0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            files: node.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )

        guard !isRoot, result.files.isEmpty, result.directories.count == 1,
              let child = result.directories.first else {
            return result
        }

        return GitCommitFileTreeNode(
            path: child.path,
            name: "\(result.name)/\(child.name)",
            directories: child.directories,
            files: child.files
        )
    }
}

private final class MutableGitCommitFileTreeNode {
    let path: String
    let name: String
    var directories: [String: MutableGitCommitFileTreeNode] = [:]
    var files: [GitCommitFile] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
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

    /// True while a merge, rebase, cherry-pick, or revert has left this file
    /// unmerged. Git marks these with a `U` on either side, plus the `AA` and `DD`
    /// pairs for both-added and both-deleted.
    var isConflicted: Bool {
        if indexStatus == "U" || workTreeStatus == "U" { return true }
        return (indexStatus == "A" && workTreeStatus == "A")
            || (indexStatus == "D" && workTreeStatus == "D")
    }

    var kind: GitChangeKind {
        // Checked first: an unmerged pair such as `AA` or `UD` would otherwise
        // match the plain added/deleted cases below and read as an ordinary edit.
        if isConflicted { return .conflicted }
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
        if isConflicted { return "!" }
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
    case conflicted

    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .moved: "Moved"
        case .copied: "Copied"
        case .conflicted: "Conflicted"
        }
    }

    var symbol: String {
        switch self {
        case .added: "plus"
        case .modified: "pencil"
        case .deleted: "minus"
        case .moved: "arrow.right"
        case .copied: "doc.on.doc"
        case .conflicted: "exclamationmark.triangle"
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
    /// Derived from the row's hunk and line numbers rather than a fresh UUID so
    /// that re-parsing the same diff keeps scroll position and difference
    /// selection stable across refreshes.
    let id: DiffRowID
    let oldLine: Int?
    let newLine: Int?
    /// Text of the left (old) side. For `context` and `information` rows this is
    /// the text of both sides; see `rightText`.
    let left: String?
    /// Text of the right (new) side, stored only when it differs from `left`.
    /// Prefer `rightText`, which folds in the shared-text cases.
    let storedRight: String?
    let kind: DiffRowKind
    let hunkID: String?

    /// Right-side text with the shared-text fallback applied. `context` and
    /// `information` rows hold identical text on both sides, so the parser only
    /// keeps one copy.
    var rightText: String? {
        switch kind {
        case .context, .information:
            return storedRight ?? left
        case .changed, .addition, .removal:
            return storedRight
        }
    }

    init(
        oldLine: Int?,
        newLine: Int?,
        left: String?,
        right: String?,
        kind: DiffRowKind,
        hunkID: String? = nil,
        sequence: Int = 0
    ) {
        self.id = DiffRowID(hunkID: hunkID, oldLine: oldLine, newLine: newLine, sequence: sequence)
        self.oldLine = oldLine
        self.newLine = newLine
        self.left = left
        switch kind {
        case .context, .information:
            // Both sides carry the same text; drop the duplicate copy.
            self.storedRight = nil
        case .changed, .addition, .removal:
            self.storedRight = right
        }
        self.kind = kind
        self.hunkID = hunkID
    }
}

/// Stable, value-derived row identity. `sequence` disambiguates rows that share
/// a hunk and line numbers, such as consecutive one-sided rows.
struct DiffRowID: Hashable, Sendable {
    let hunkID: String?
    let oldLine: Int?
    let newLine: Int?
    let sequence: Int
}

struct DiffHunk: Identifiable, Sendable {
    let id: String
    let header: String
    let patch: String
}

struct DiffDocument: Sendable {
    let patch: String
    let rows: [DiffRow]
    let hunks: [DiffHunk]

    init(patch: String = "", rows: [DiffRow], hunks: [DiffHunk]) {
        self.patch = patch
        self.rows = rows
        self.hunks = hunks
    }
}

struct DiffHunkRequest: Identifiable {
    let id = UUID()
    let change: GitChange
    let hunk: DiffHunk
}

/// A checkout that local changes would overwrite, awaiting the user's resolution choice.
struct GitCheckoutConflictRequest: Identifiable {
    let id = UUID()
    let reference: GitReference
    let blockingPaths: [String]
}

/// The destructive rollback requested from a conflict dialog. The original
/// operation is retained so a successful rollback can re-run its preflight and
/// continue automatically when no blocking paths remain.
enum GitConflictResume: Sendable {
    case checkout(GitReference)
    case integration(target: GitIntegrationTarget, operation: GitIntegrationOperation)
}

struct GitConflictRollbackRequest: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let resume: GitConflictResume
}

/// What stands in the way of starting a merge or rebase.
struct GitIntegrationPreflightState: Sendable {
    let blockingPaths: [String]
    /// True for a rebase, which refuses on any uncommitted change rather than
    /// only those overlapping the incoming commits.
    let blocksEntirely: Bool

    var isClear: Bool { blockingPaths.isEmpty }
}

/// What an integration replays: a whole branch, or a single commit.
///
/// Merge and rebase name a branch while cherry-pick and revert name one commit,
/// but the preflight only needs a revision to resolve, so they share this.
enum GitIntegrationTarget: Sendable {
    case reference(GitReference)
    case commit(GitCommit)

    /// The revision handed to Git.
    var revision: String {
        switch self {
        case .reference(let reference): reference.fullName
        case .commit(let commit): commit.hash
        }
    }

    /// The revision as the user knows it, for messages.
    var displayName: String {
        switch self {
        case .reference(let reference): reference.shortName
        case .commit(let commit): commit.shortHash
        }
    }
}

/// An integration blocked by uncommitted changes, awaiting the user's choice.
struct GitIntegrationConflictRequest: Identifiable {
    let id = UUID()
    let target: GitIntegrationTarget
    let operation: GitIntegrationOperation
    let blockingPaths: [String]
    let blocksEntirely: Bool
}

/// A stash created by Lithe could not be restored cleanly. The entry is kept so
/// the user can resolve the working tree and drop it explicitly afterwards.
struct GitStashRestoreConflictRequest: Identifiable, Sendable {
    let id = UUID()
    let stashReference: String
    let conflictedPaths: [String]
    let operationTitle: String

    var hasConflictPaths: Bool { !conflictedPaths.isEmpty }
}

struct GitDeferredSavedChanges: Sendable {
    let stashReference: String?
    let shelfID: UUID?
    let operationTitle: String

    init(stashReference: String, operationTitle: String) {
        self.stashReference = stashReference
        shelfID = nil
        self.operationTitle = operationTitle
    }

    init(shelfID: UUID, operationTitle: String) {
        stashReference = nil
        self.shelfID = shelfID
        self.operationTitle = operationTitle
    }
}

struct GitShelfEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let message: String
    let createdAt: Date
    let paths: [String]
    let stagedPatch: String
    let workingPatch: String
}

/// The branch-integration operations that share a preflight.
enum GitIntegrationOperation: String, Sendable {
    case merge
    case rebase
    case cherryPick
    case revert

    var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }
}

/// Whether a pull can fast-forward, and how far the two sides have drifted.
struct GitPullPreflightState: Sendable {
    let upstream: String?
    let ahead: Int
    let behind: Int
    let diverged: Bool
    let hasLocalChanges: Bool

    /// Nothing to pull, so the network call can be skipped entirely.
    var isUpToDate: Bool { behind == 0 && !diverged }
}

/// A pull that cannot fast-forward, awaiting the user's choice of strategy.
struct GitPullStrategyRequest: Identifiable {
    let id = UUID()
    let upstream: String
    let ahead: Int
    let behind: Int
    let hasLocalChanges: Bool
}

/// How to reconcile a divergent history when pulling.
enum GitPullStrategy: String, Sendable {
    /// Refuse unless the pull can fast-forward. The safe default.
    case ffOnly
    /// Join the two histories with a merge commit.
    case merge
    /// Replay local commits on top of the upstream, keeping history linear.
    case rebase
}

enum GitOperationKind: String, Equatable, Sendable {
    case merge
    case rebase
    case cherryPick
    case revert

    var title: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        }
    }

    /// Whole literal keys rather than interpolating `title`, so translators get a
    /// complete sentence per operation instead of a fragment.
    var inProgressTitle: String {
        switch self {
        case .merge: "Merge in progress"
        case .rebase: "Rebase in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        }
    }

    var continueTitle: String {
        switch self {
        case .merge: "Continue Merge"
        case .rebase: "Continue Rebase"
        case .cherryPick: "Continue Cherry-pick"
        case .revert: "Continue Revert"
        }
    }

    /// Only a rebase replays a sequence of commits, so it alone can skip one.
    var canSkip: Bool { self == .rebase }
}

/// A merge, rebase, cherry-pick, or revert that Git left half-finished, usually
/// because it hit conflicts. Absent when the repository is in its normal state.
struct GitOperationState: Equatable, Sendable {
    let kind: GitOperationKind
    let reference: String?
    let step: Int?
    let total: Int?
    let conflictedPaths: [String]

    var hasConflicts: Bool { !conflictedPaths.isEmpty }

    /// Rebase progress as `3/7`, nil for operations that replay a single commit.
    var progress: String? {
        guard let step, let total, total > 0 else { return nil }
        return "\(step)/\(total)"
    }
}

/// How to resolve a checkout blocked by local changes.
enum GitCheckoutConflictStrategy: Sendable {
    /// Stash the local changes, switch, then restore them.
    case smart
    /// Switch and discard the local changes.
    case force
}

enum GitSaveChangesPolicy: String, CaseIterable, Identifiable, Sendable {
    case stash
    case shelve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stash: "Git stash"
        case .shelve: "Lithe Shelve"
        }
    }

    var description: String {
        switch self {
        case .stash: "Store temporary changes in Git's stash list."
        case .shelve: "Store patches in Lithe without adding objects to Git."
        }
    }
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
        // Monotonic per-document counter that keeps DiffRowID unique even when
        // rows share a hunk and line numbers.
        var rowSequence = 0
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
                    hunkID: currentHunkID,
                    sequence: rowSequence
                ))
                rowSequence += 1
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
                    right: nil,
                    kind: .information,
                    hunkID: hunkID,
                    sequence: rowSequence
                ))
                rowSequence += 1
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
                rows.append(DiffRow(
                    oldLine: oldLine,
                    newLine: newLine,
                    left: String(line.dropFirst()),
                    right: nil,
                    kind: .context,
                    hunkID: currentHunkID,
                    sequence: rowSequence
                ))
                rowSequence += 1
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
