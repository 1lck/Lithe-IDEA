import Foundation
import LitheCoreContracts

package typealias GitWatchContext = LitheCoreContracts.GitWatchContext

/// Mirrors the shared Rust refname checks used by tag mutations so the macOS
/// dialog can reject the same invalid names before crossing the Core boundary.
public enum GitTagNameValidator {
    public static func isValid(_ value: String) -> Bool {
        !isInvalid(value)
    }

    public static func validationError(for value: String) -> String? {
        isInvalid(value) ? "Invalid Git tag name." : nil
    }

    private static func isInvalid(_ value: String) -> Bool {
        if value.isEmpty
            || value.hasPrefix("-")
            || value == "@"
            || value.hasPrefix("/")
            || value.hasSuffix("/")
            || value.hasSuffix(".")
            || value.contains("..")
            || value.contains("@{")
            || value.contains("//")
        {
            return true
        }
        if value.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || " ~^:?*[\\".unicodeScalars.contains(scalar)
        }) {
            return true
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).contains { component in
            component.hasPrefix(".") || component.hasSuffix(".lock")
        }
    }
}

package struct GitSnapshot: Sendable {
    package let repositoryRoot: URL
    package let branch: String
    package let changes: [GitChange]
    package init(repositoryRoot: URL, branch: String, changes: [GitChange]) { self.repositoryRoot = repositoryRoot; self.branch = branch; self.changes = changes }
}

package enum GitWorktreeLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

package enum GitWorktreeInspectionLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

package struct GitWorktreeInspection: Sendable {
    package let worktreeID: String
    package let changes: [GitChange]
    package let commits: [GitCommit]
    package let hasMoreCommits: Bool
    package let hasLoadedChanges: Bool

    package init(
        worktreeID: String,
        changes: [GitChange],
        commits: [GitCommit],
        hasMoreCommits: Bool = false,
        hasLoadedChanges: Bool = true
    ) {
        self.worktreeID = worktreeID
        self.changes = changes
        self.commits = commits
        self.hasMoreCommits = hasMoreCommits
        self.hasLoadedChanges = hasLoadedChanges
    }
}

package struct GitWorktree: Identifiable, Hashable, Sendable {
    package let path: String
    package let head: String
    package let branch: String?
    package let isCurrent: Bool
    package let isPrimary: Bool
    package let isBare: Bool
    package let isDetached: Bool
    package let isLocked: Bool
    package let lockReason: String?
    package let isPrunable: Bool
    package let pruneReason: String?

    package init(
        path: String,
        head: String,
        branch: String?,
        isCurrent: Bool,
        isPrimary: Bool,
        isBare: Bool,
        isDetached: Bool,
        isLocked: Bool,
        lockReason: String?,
        isPrunable: Bool,
        pruneReason: String?
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isCurrent = isCurrent
        self.isPrimary = isPrimary
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.pruneReason = pruneReason
    }

    package var id: String { path }
    package var url: URL { URL(fileURLWithPath: path) }
    package var shortHead: String { String(head.prefix(8)) }
    package var branchName: String? {
        guard let branch else { return nil }
        let prefix = "refs/heads/"
        return branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
    }
    package var displayName: String {
        branchName ?? (isBare ? "Bare repository" : "Detached HEAD")
    }
}

/// Stable, renderer-neutral status used by the Worktrees list projection.
package enum GitWorktreeStatusKind: String, Equatable, Sendable {
    case pathMissing
    case locked
    case modified
    case current
    case available
}

/// Worktree row data prepared outside the SwiftUI render path.
package struct GitWorktreeListItem: Identifiable, Equatable, Sendable {
    package let worktree: GitWorktree
    package let status: GitWorktreeStatusKind

    package var id: String { worktree.id }

    package init(worktree: GitWorktree, status: GitWorktreeStatusKind) {
        self.worktree = worktree
        self.status = status
    }
}

package enum GitWorktreeListProjection {
    /// Filters and classifies rows with one linear pass. The inspection is
    /// passed as a value so unrelated Git model publications cannot trigger
    /// repeated status lookups for every row.
    package static func items(
        worktrees: [GitWorktree],
        query rawQuery: String,
        inspection: GitWorktreeInspection?,
        currentChangeCount: Int
    ) -> [GitWorktreeListItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return worktrees.compactMap { worktree in
            if !query.isEmpty,
               !worktree.displayName.localizedCaseInsensitiveContains(query),
               !worktree.path.localizedCaseInsensitiveContains(query),
               !(worktree.branchName?.localizedCaseInsensitiveContains(query) ?? false)
            {
                return nil
            }

            let status: GitWorktreeStatusKind
            if worktree.isPrunable {
                status = .pathMissing
            } else if worktree.isLocked {
                status = .locked
            } else if inspection?.worktreeID == worktree.id, let inspection, !inspection.changes.isEmpty {
                status = .modified
            } else if worktree.isCurrent, currentChangeCount > 0 {
                status = .modified
            } else if worktree.isCurrent {
                status = .current
            } else {
                status = .available
            }
            return GitWorktreeListItem(worktree: worktree, status: status)
        }
    }
}

package enum GitReferenceKind: String, Sendable {
    case local
    case remote
    case tag
}

package struct GitReference: Identifiable, Hashable, Sendable {
    package let fullName: String
    package let shortName: String
    package let kind: GitReferenceKind
    package let peelsToCommit: Bool
    package let isCurrent: Bool
    package let upstreamShortName: String?
    package init(
        fullName: String,
        shortName: String,
        kind: GitReferenceKind,
        peelsToCommit: Bool = true,
        isCurrent: Bool,
        upstreamShortName: String?
    ) {
        self.fullName = fullName
        self.shortName = shortName
        self.kind = kind
        self.peelsToCommit = peelsToCommit
        self.isCurrent = isCurrent
        self.upstreamShortName = upstreamShortName
    }

    package var id: String { fullName }
    package var supportsTagDeletion: Bool { kind == .tag && peelsToCommit }
}

package struct GitStash: Identifiable, Hashable, Sendable {
    package let reference: String
    package let message: String
    package let branch: String?
    package let date: String
    package init(reference: String, message: String, branch: String?, date: String) { self.reference = reference; self.message = message; self.branch = branch; self.date = date }

    package var id: String { reference }
}

/// Structured information returned when `git stash pop` keeps the entry because
/// restoring it created unresolved conflicts. The stash is intentionally not
/// dropped so the user can finish recovery without losing the original patch.
public struct GitStashRestoreConflict: Hashable, Sendable {
    public let stashReference: String
    public let conflictedPaths: [String]

    public init(stashReference: String, conflictedPaths: [String]) {
        self.stashReference = stashReference
        self.conflictedPaths = conflictedPaths
    }
}

package struct GitCommit: Identifiable, Hashable, Sendable {
    package let hash: String
    package let shortHash: String
    package let parentHashes: [String]
    package let authorName: String
    package let authorEmail: String
    package let date: String
    package let subject: String
    package let decorations: String
    package init(hash: String, shortHash: String, parentHashes: [String], authorName: String, authorEmail: String, date: String, subject: String, decorations: String) { self.hash = hash; self.shortHash = shortHash; self.parentHashes = parentHashes; self.authorName = authorName; self.authorEmail = authorEmail; self.date = date; self.subject = subject; self.decorations = decorations }

    package var id: String { hash }
}

package struct GitCommitFile: Identifiable, Hashable, Sendable {
    package let status: String
    package let path: String
    package init(status: String, path: String) { self.status = status; self.path = path }

    package var id: String { "\(status):\(path)" }
}

package struct GitCommitFileTreeNode: Identifiable, Equatable, Sendable {
    package let path: String
    package let name: String
    package let directories: [GitCommitFileTreeNode]
    package let files: [GitCommitFile]
    package let fileCount: Int

    package var id: String { path.isEmpty ? "." : path }

    package static func build(from files: [GitCommitFile], rootName: String) -> GitCommitFileTreeNode {
        let root = MutableGitCommitFileTreeNode(name: rootName, path: "")

        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else {
                root.files.append(file)
                continue
            }

            var node = root
            var currentPath = ""
            for component in components.dropLast() {
                let name = String(component)
                if currentPath.isEmpty {
                    currentPath = name
                } else {
                    currentPath += "/"
                    currentPath += name
                }
                if node.directories[name] == nil {
                    node.directories[name] = MutableGitCommitFileTreeNode(name: name, path: currentPath)
                }
                node = node.directories[name]!
            }
            node.files.append(file)
        }

        return makeNode(from: root, isRoot: true)
    }

    private static func makeNode(
        from node: MutableGitCommitFileTreeNode,
        isRoot: Bool = false
    ) -> GitCommitFileTreeNode {
        let directories = node.directories.values
            .map { makeNode(from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let files = node.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let result = GitCommitFileTreeNode(
            path: node.path,
            name: node.name,
            directories: directories,
            files: files,
            fileCount: files.count + directories.reduce(0) { $0 + $1.fileCount }
        )

        guard !isRoot, result.files.isEmpty, result.directories.count == 1,
              let child = result.directories.first else {
            return result
        }

        return GitCommitFileTreeNode(
            path: child.path,
            name: "\(result.name)/\(child.name)",
            directories: child.directories,
            files: child.files,
            fileCount: child.fileCount
        )
    }
}

private final class MutableGitCommitFileTreeNode {
    package let path: String
    package let name: String
    package var directories: [String: MutableGitCommitFileTreeNode] = [:]
    package var files: [GitCommitFile] = []

    package init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Read-only diff context for a file changed by a historical commit.
package struct GitCommitDiffContext: Identifiable, Hashable, Sendable {
    package let repositoryRoot: URL
    package let commit: GitCommit
    package let file: GitCommitFile

    package var id: String { "\(commit.hash):\(file.id)" }
    package var path: String { file.path }
    package var url: URL { repositoryRoot.appendingPathComponent(file.path) }

    package var kind: GitChangeKind {
        if file.status.hasPrefix("A") { return .added }
        if file.status.hasPrefix("D") { return .deleted }
        if file.status.hasPrefix("R") { return .moved }
        if file.status.hasPrefix("C") { return .copied }
        return .modified
    }
}

package struct GitBlameLine: Identifiable, Hashable, Sendable {
    package let line: Int
    package let commitHash: String
    package let authorName: String
    package let date: String
    package init(line: Int, commitHash: String, authorName: String, date: String) { self.line = line; self.commitHash = commitHash; self.authorName = authorName; self.date = date }

    package var id: Int { line }
}

package struct GitBranchComparisonFile: Identifiable, Hashable, Sendable {
    package let status: String
    package let path: String
    package let isUntracked: Bool
    package init(status: String, path: String, isUntracked: Bool = false) {
        self.status = status
        self.path = path
        self.isUntracked = isUntracked
    }

    package var id: String { "\(status):\(path):\(isUntracked)" }
}

package struct GitBranchComparison: Identifiable, Sendable {
    package let reference: GitReference
    package let targetReference: GitReference?
    package let files: [GitBranchComparisonFile]
    package init(
        reference: GitReference,
        targetReference: GitReference? = nil,
        files: [GitBranchComparisonFile]
    ) {
        self.reference = reference
        self.targetReference = targetReference
        self.files = files
    }

    package var id: String { "\(reference.id)..\(targetReference?.id ?? "working-tree")" }
    package var targetTitle: String { targetReference?.shortName ?? "Working Tree" }
}

package struct GitHistorySnapshot: Sendable {
    package let references: [GitReference]
    package let recentReferences: [GitReference]
    package let commits: [GitCommit]
    package let hasMore: Bool
    package let identity: GitIdentity?
    package init(
        references: [GitReference],
        recentReferences: [GitReference] = [],
        commits: [GitCommit],
        hasMore: Bool,
        identity: GitIdentity? = nil
    ) {
        self.references = references
        self.recentReferences = recentReferences
        self.commits = commits
        self.hasMore = hasMore
        self.identity = identity
    }
}

package struct GitReferenceSnapshot: Sendable {
    package let references: [GitReference]
    package let recentReferences: [GitReference]
    package let identity: GitIdentity?

    package init(
        references: [GitReference],
        recentReferences: [GitReference] = [],
        identity: GitIdentity? = nil
    ) {
        self.references = references
        self.recentReferences = recentReferences
        self.identity = identity
    }
}

package struct GitHistoryPage: Sendable {
    package let commits: [GitCommit]
    package let nextCursor: String?
    package let hasMore: Bool

    package init(commits: [GitCommit], nextCursor: String?, hasMore: Bool) {
        self.commits = commits
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

package struct GitIdentity: Hashable, Sendable {
    package let name: String?
    package let email: String?

    package init(name: String?, email: String?) {
        self.name = name?.nilIfBlank
        self.email = email?.nilIfBlank
    }

    package var isEmpty: Bool { name == nil && email == nil }
}

package struct GitLogQuery: Equatable, Sendable {
    package let textTerms: [String]
    package let authors: [String]
    package let branches: [String]
    package let paths: [String]
    package let afterDate: Date?
    package let beforeDate: Date?
    package let currentUserOnly: Bool
    package let exactAuthor: GitIdentity?

    package init(
        textTerms: [String] = [],
        authors: [String] = [],
        branches: [String] = [],
        paths: [String] = [],
        afterDate: Date? = nil,
        beforeDate: Date? = nil,
        currentUserOnly: Bool = false,
        exactAuthor: GitIdentity? = nil
    ) {
        self.textTerms = textTerms
        self.authors = authors
        self.branches = branches
        self.paths = paths.map { $0.replacingOccurrences(of: "\\", with: "/") }
        self.afterDate = afterDate
        self.beforeDate = beforeDate
        self.currentUserOnly = currentUserOnly
        self.exactAuthor = exactAuthor
    }

    package var isEmpty: Bool {
        textTerms.isEmpty
            && authors.isEmpty
            && branches.isEmpty
            && paths.isEmpty
            && afterDate == nil
            && beforeDate == nil
            && !currentUserOnly
            && exactAuthor == nil
    }

    package static func parse(_ rawValue: String) -> GitLogQuery {
        var textTerms: [String] = []
        var authors: [String] = []
        var branches: [String] = []
        var paths: [String] = []
        var afterDate: Date?
        var beforeDate: Date?
        var currentUserOnly = false

        for token in tokenize(rawValue) {
            if token.caseInsensitiveCompare("me") == .orderedSame {
                currentUserOnly = true
                continue
            }
            let pieces = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[1].isEmpty else {
                textTerms.append(token)
                continue
            }
            let value = String(pieces[1])
            switch pieces[0].lowercased() {
            case "author": authors.append(value)
            case "branch": branches.append(value)
            case "path": paths.append(value.replacingOccurrences(of: "\\", with: "/"))
            case "after", "since":
                guard let parsedDate = parseBoundaryDate(value) else {
                    textTerms.append(token)
                    continue
                }
                afterDate = afterDate.map { max($0, parsedDate) } ?? parsedDate
            case "before", "until":
                guard let parsedDate = parseBoundaryDate(value) else {
                    textTerms.append(token)
                    continue
                }
                beforeDate = beforeDate.map { min($0, parsedDate) } ?? parsedDate
            default: textTerms.append(token)
            }
        }
        return GitLogQuery(
            textTerms: textTerms,
            authors: authors,
            branches: branches,
            paths: paths,
            afterDate: afterDate,
            beforeDate: beforeDate,
            currentUserOnly: currentUserOnly
        )
    }

    package func addingStructuredFilters(
        currentUserOnly: Bool = false,
        exactAuthor: GitIdentity? = nil,
        paths: [String] = [],
        afterDate: Date? = nil,
        beforeDate: Date? = nil
    ) -> GitLogQuery {
        GitLogQuery(
            textTerms: textTerms,
            authors: authors,
            branches: branches,
            paths: self.paths + paths,
            afterDate: Self.laterBoundary(afterDate, self.afterDate),
            beforeDate: Self.earlierBoundary(beforeDate, self.beforeDate),
            currentUserOnly: self.currentUserOnly || currentUserOnly,
            exactAuthor: exactAuthor ?? self.exactAuthor
        )
    }

    package func matchesMetadata(_ commit: GitCommit, identity: GitIdentity?) -> Bool {
        if afterDate != nil || beforeDate != nil {
            guard let commitDate = Self.parseCommitDate(commit.date) else { return false }
            if let afterDate, commitDate < afterDate { return false }
            if let beforeDate, commitDate >= beforeDate { return false }
        }
        if currentUserOnly {
            guard let identity, !identity.isEmpty else { return false }
            let matchesName = identity.name.map {
                commit.authorName.caseInsensitiveCompare($0) == .orderedSame
            } ?? false
            let matchesEmail = identity.email.map {
                commit.authorEmail.caseInsensitiveCompare($0) == .orderedSame
            } ?? false
            guard matchesName || matchesEmail else { return false }
        }
        if let exactAuthor {
            let matchesExactAuthor: Bool
            if let email = exactAuthor.email {
                matchesExactAuthor = commit.authorEmail.caseInsensitiveCompare(email) == .orderedSame
            } else if let name = exactAuthor.name {
                matchesExactAuthor = commit.authorName.caseInsensitiveCompare(name) == .orderedSame
            } else {
                matchesExactAuthor = false
            }
            guard matchesExactAuthor else { return false }
        }
        if !authors.isEmpty {
            guard authors.contains(where: { author in
                commit.authorName.localizedCaseInsensitiveContains(author)
                    || commit.authorEmail.localizedCaseInsensitiveContains(author)
            }) else { return false }
        }
        let searchable = [
            commit.subject, commit.hash, commit.shortHash,
            commit.authorName, commit.authorEmail, commit.decorations
        ]
        return textTerms.allSatisfy { term in
            searchable.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    package func matchesPaths(_ changedPaths: Set<String>) -> Bool {
        paths.allSatisfy { filter in
            changedPaths.contains { path in
                path.localizedCaseInsensitiveContains(filter)
            }
        }
    }

    private static func tokenize(_ rawValue: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in rawValue {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
            } else if character.isWhitespace, quote == nil {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func laterBoundary(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (.some(first), .some(second)): return max(first, second)
        case let (.some(first), .none): return first
        case let (.none, .some(second)): return second
        case (.none, .none): return nil
        }
    }

    private static func earlierBoundary(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (.some(first), .some(second)): return min(first, second)
        case let (.some(first), .none): return first
        case let (.none, .some(second)): return second
        case (.none, .none): return nil
        }
    }

    private static func parseBoundaryDate(_ value: String) -> Date? {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func parseCommitDate(_ value: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        if let date = iso8601.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        for format in [
            "EEE MMM d HH:mm:ss yyyy Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy/MM/dd HH:mm"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

package struct GitChange: Identifiable, Hashable, Sendable {
    package let repositoryRoot: URL
    package let path: String
    package let originalPath: String?
    package let indexStatus: Character
    package let workTreeStatus: Character
    package init(repositoryRoot: URL, path: String, originalPath: String?, indexStatus: Character, workTreeStatus: Character) { self.repositoryRoot = repositoryRoot; self.path = path; self.originalPath = originalPath; self.indexStatus = indexStatus; self.workTreeStatus = workTreeStatus }

    package var id: String { "\(originalPath ?? "")->\(path)" }
    package var url: URL { repositoryRoot.appendingPathComponent(path) }
    package var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    package var hasWorkingTreeChange: Bool { workTreeStatus != " " }
    package var isUntracked: Bool { indexStatus == "?" && workTreeStatus == "?" }

    /// True while a merge, rebase, cherry-pick, or revert has left this file
    /// unmerged. Git marks these with a `U` on either side, plus the `AA` and `DD`
    /// pairs for both-added and both-deleted.
    package var isConflicted: Bool {
        if indexStatus == "U" || workTreeStatus == "U" { return true }
        return (indexStatus == "A" && workTreeStatus == "A")
            || (indexStatus == "D" && workTreeStatus == "D")
    }

    package var kind: GitChangeKind {
        // Checked first: an unmerged pair such as `AA` or `UD` would otherwise
        // match the plain added/deleted cases below and read as an ordinary edit.
        if isConflicted { return .conflicted }
        if isUntracked || indexStatus == "A" || workTreeStatus == "A" { return .added }
        if indexStatus == "D" || workTreeStatus == "D" { return .deleted }
        if indexStatus == "R" || workTreeStatus == "R" { return .moved }
        if indexStatus == "C" || workTreeStatus == "C" { return .copied }
        return .modified
    }

    package var pathspecs: [String] {
        if let originalPath, originalPath != path { return [originalPath, path] }
        return [path]
    }

    package var displayStatus: String {
        if isConflicted { return "!" }
        if isUntracked { return "A" }
        if workTreeStatus != " " { return String(workTreeStatus) }
        return String(indexStatus)
    }
}

package enum GitChangeKind: String, Sendable {
    case added
    case modified
    case deleted
    case moved
    case copied
    case conflicted

    package var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .moved: "Moved"
        case .copied: "Copied"
        case .conflicted: "Conflicted"
        }
    }

    package var symbol: String {
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

/// Projects repository-relative Git changes onto file and directory rows.
/// Directory status uses the most urgent descendant state so conflicts and
/// deletions are never hidden behind a lower-priority modification.
package struct GitTreeStatusProjection: Equatable, Sendable {
    private let changesByPath: [String: GitChange]
    private let directoryKinds: [String: GitChangeKind]

    package init(changes: [GitChange]) {
        var changesByPath: [String: GitChange] = [:]
        var directoryKinds: [String: GitChangeKind] = [:]
        for change in changes {
            let path = Self.normalized(change.path)
            if changesByPath[path] == nil {
                changesByPath[path] = change
            }
            var remainder = path
            while let slash = remainder.lastIndex(of: "/") {
                remainder = String(remainder[..<slash])
                if let current = directoryKinds[remainder] {
                    if Self.priority(change.kind) > Self.priority(current) {
                        directoryKinds[remainder] = change.kind
                    }
                } else {
                    directoryKinds[remainder] = change.kind
                }
            }
            if !path.isEmpty {
                if let current = directoryKinds[""] {
                    if Self.priority(change.kind) > Self.priority(current) {
                        directoryKinds[""] = change.kind
                    }
                } else {
                    directoryKinds[""] = change.kind
                }
            }
        }
        self.changesByPath = changesByPath
        self.directoryKinds = directoryKinds
    }

    package func change(relativePath: String) -> GitChange? {
        changesByPath[Self.normalized(relativePath)]
    }

    package func kind(relativePath: String, isDirectory: Bool) -> GitChangeKind? {
        let normalized = Self.normalized(relativePath)
        if !isDirectory {
            return changesByPath[normalized]?.kind
        }
        return directoryKinds[normalized]
    }

    private static func priority(_ kind: GitChangeKind) -> Int {
        switch kind {
        case .modified: 0
        case .copied: 1
        case .moved: 2
        case .added: 3
        case .deleted: 4
        case .conflicted: 5
        }
    }

    private static func normalized(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

package extension GitChangeKind {
    var commitMessageKind: CommitMessageChangeKind {
        switch self {
        case .added: .added
        case .modified: .modified
        case .deleted: .deleted
        case .moved: .renamed
        case .copied: .copied
        case .conflicted: .unmerged
        }
    }
}


package enum GitDiffWhitespaceMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case doNotIgnore
    case ignoreAllWhitespace

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .doNotIgnore:
            return "Do not ignore"
        case .ignoreAllWhitespace:
            return "Ignore whitespace"
        }
    }
}

package enum DiffRowKind: Sendable, Equatable {
    case context
    case changed
    case addition
    case removal
    case information
}

package struct DiffRow: Identifiable, Sendable {
    /// Derived from the row's hunk and line numbers rather than a fresh UUID so
    /// that re-parsing the same diff keeps scroll position and difference
    /// selection stable across refreshes.
    package let id: DiffRowID
    package let oldLine: Int?
    package let newLine: Int?
    /// Text of the left (old) side. For `context` and `information` rows this is
    /// the text of both sides; see `rightText`.
    package let left: String?
    /// Text of the right (new) side, stored only when it differs from `left`.
    /// Prefer `rightText`, which folds in the shared-text cases.
    package let storedRight: String?
    package let kind: DiffRowKind
    package let hunkID: String?

    /// Right-side text with the shared-text fallback applied. `context` and
    /// `information` rows hold identical text on both sides, so the parser only
    /// keeps one copy.
    package var rightText: String? {
        switch kind {
        case .context, .information:
            return storedRight ?? left
        case .changed, .addition, .removal:
            return storedRight
        }
    }

    package init(
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
package struct DiffRowID: Hashable, Sendable {
    package let hunkID: String?
    package let oldLine: Int?
    package let newLine: Int?
    package let sequence: Int
}

package struct DiffHunk: Identifiable, Sendable {
    package let id: String
    package let header: String
    package let patch: String
    package init(id: String, header: String, patch: String) { self.id = id; self.header = header; self.patch = patch }
}

package struct DiffDocument: Sendable {
    package let patch: String
    package let rows: [DiffRow]
    package let hunks: [DiffHunk]

    package init(patch: String = "", rows: [DiffRow], hunks: [DiffHunk]) {
        self.patch = patch
        self.rows = rows
        self.hunks = hunks
    }
}

package enum GitLineChangeKind: String, Sendable {
    case added
    case modified
    case deleted
}

package struct GitLineChangeMarker: Identifiable, Hashable, Sendable {
    package let line: Int
    package let kind: GitLineChangeKind
    package let hunkID: String?

    package var id: String { "\(line):\(kind.rawValue):\(hunkID ?? "")" }
}

/// Converts right-side diff rows into zero-based editor gutter markers.
/// Removed rows anchor to the following surviving line, or the final line when
/// the deletion occurs at end of file, matching conventional IDE gutters.
package enum GitLineChangeProjection {
    package static func markers(from rows: [DiffRow]) -> [GitLineChangeMarker] {
        var markersByLine: [Int: GitLineChangeMarker] = [:]
        var lastNewLine: Int?

        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .addition:
                if let newLine = row.newLine {
                    insert(
                        GitLineChangeMarker(line: max(0, newLine - 1), kind: .added, hunkID: row.hunkID),
                        into: &markersByLine
                    )
                    lastNewLine = newLine
                }
            case .changed:
                if let newLine = row.newLine {
                    insert(
                        GitLineChangeMarker(line: max(0, newLine - 1), kind: .modified, hunkID: row.hunkID),
                        into: &markersByLine
                    )
                    lastNewLine = newLine
                }
            case .removal:
                let nextNewLine = rows[(index + 1)...]
                    .lazy
                    .compactMap(\.newLine)
                    .first
                let anchor = max(0, (nextNewLine ?? lastNewLine ?? 1) - 1)
                insert(
                    GitLineChangeMarker(line: anchor, kind: .deleted, hunkID: row.hunkID),
                    into: &markersByLine
                )
            case .context:
                if let newLine = row.newLine { lastNewLine = newLine }
            case .information:
                break
            }
        }

        return markersByLine.values.sorted {
            ($0.line, priority($0.kind), $0.hunkID ?? "")
                < ($1.line, priority($1.kind), $1.hunkID ?? "")
        }
    }

    private static func insert(
        _ marker: GitLineChangeMarker,
        into markersByLine: inout [Int: GitLineChangeMarker]
    ) {
        guard let current = markersByLine[marker.line] else {
            markersByLine[marker.line] = marker
            return
        }
        if priority(marker.kind) > priority(current.kind) {
            markersByLine[marker.line] = marker
        }
    }

    private static func priority(_ kind: GitLineChangeKind) -> Int {
        switch kind {
        case .added: 0
        case .deleted: 1
        case .modified: 2
        }
    }
}

package struct DiffHunkRequest: Identifiable {
    package let id = UUID()
    package let change: GitChange
    package let hunk: DiffHunk
}

/// A checkout that local changes would overwrite, awaiting the user's resolution choice.
package struct GitCheckoutConflictRequest: Identifiable {
    package let id = UUID()
    package let reference: GitReference
    package let blockingPaths: [String]
}

/// The destructive rollback requested from a conflict dialog. The original
/// operation is retained so a successful rollback can re-run its preflight and
/// continue automatically when no blocking paths remain.
package enum GitConflictResume: Sendable {
    case checkout(GitReference)
    case integration(target: GitIntegrationTarget, operation: GitIntegrationOperation)
}

package struct GitConflictRollbackRequest: Identifiable, Sendable {
    package let id = UUID()
    package let path: String
    package let resume: GitConflictResume
}

/// What stands in the way of starting a merge or rebase.
package struct GitIntegrationPreflightState: Sendable {
    package let blockingPaths: [String]
    /// True for a rebase, which refuses on any uncommitted change rather than
    /// only those overlapping the incoming commits.
    package let blocksEntirely: Bool
    package init(blockingPaths: [String], blocksEntirely: Bool) { self.blockingPaths = blockingPaths; self.blocksEntirely = blocksEntirely }

    package var isClear: Bool { blockingPaths.isEmpty }
}

/// What an integration replays: a whole branch, or a single commit.
///
/// Merge and rebase name a branch while cherry-pick and revert name one commit,
/// but the preflight only needs a revision to resolve, so they share this.
package enum GitIntegrationTarget: Sendable {
    case reference(GitReference)
    case commit(GitCommit)

    /// The revision handed to Git.
    package var revision: String {
        switch self {
        case .reference(let reference): reference.fullName
        case .commit(let commit): commit.hash
        }
    }

    /// The revision as the user knows it, for messages.
    package var displayName: String {
        switch self {
        case .reference(let reference): reference.shortName
        case .commit(let commit): commit.shortHash
        }
    }
}

/// An integration blocked by uncommitted changes, awaiting the user's choice.
package struct GitIntegrationConflictRequest: Identifiable {
    package let id = UUID()
    package let target: GitIntegrationTarget
    package let operation: GitIntegrationOperation
    package let blockingPaths: [String]
    package let blocksEntirely: Bool
}

/// A stash created by Lithe could not be restored cleanly. The entry is kept so
/// the user can resolve the working tree and drop it explicitly afterwards.
package struct GitStashRestoreConflictRequest: Identifiable, Sendable {
    package let id = UUID()
    package let stashReference: String
    package let conflictedPaths: [String]
    package let operationTitle: String

    package var hasConflictPaths: Bool { !conflictedPaths.isEmpty }
}

package struct GitDeferredSavedChanges: Sendable {
    package let stashReference: String?
    package let shelfID: UUID?
    package let operationTitle: String

    package init(stashReference: String, operationTitle: String) {
        self.stashReference = stashReference
        shelfID = nil
        self.operationTitle = operationTitle
    }

    package init(shelfID: UUID, operationTitle: String) {
        stashReference = nil
        self.shelfID = shelfID
        self.operationTitle = operationTitle
    }
}

package struct GitShelfEntry: Identifiable, Hashable, Sendable {
    package let id: UUID
    package let message: String
    package let createdAt: Date
    package let paths: [String]
    package let stagedPatch: String
    package let workingPatch: String
}

/// The branch-integration operations that share a preflight.
package enum GitIntegrationOperation: String, Sendable {
    case merge
    case rebase
    case cherryPick
    case revert

    package var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }
}

/// Whether a pull can fast-forward, and how far the two sides have drifted.
package struct GitPullPreflightState: Sendable {
    package let upstream: String?
    package let ahead: Int
    package let behind: Int
    package let diverged: Bool
    package let hasLocalChanges: Bool
    package init(upstream: String?, ahead: Int, behind: Int, diverged: Bool, hasLocalChanges: Bool) { self.upstream = upstream; self.ahead = ahead; self.behind = behind; self.diverged = diverged; self.hasLocalChanges = hasLocalChanges }

    /// Nothing to pull, so the network call can be skipped entirely.
    package var isUpToDate: Bool { behind == 0 && !diverged }
}

/// A pull that cannot fast-forward, awaiting the user's choice of strategy.
package struct GitPullStrategyRequest: Identifiable {
    package let id = UUID()
    package let upstream: String
    package let ahead: Int
    package let behind: Int
    package let hasLocalChanges: Bool
}

/// How to reconcile a divergent history when pulling.
package enum GitPullStrategy: String, Sendable {
    /// Refuse unless the pull can fast-forward. The safe default.
    case ffOnly
    /// Join the two histories with a merge commit.
    case merge
    /// Replay local commits on top of the upstream, keeping history linear.
    case rebase
}

package enum GitOperationKind: String, Equatable, Sendable {
    case merge
    case rebase
    case cherryPick
    case revert

    package var title: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        }
    }

    /// Whole literal keys rather than interpolating `title`, so translators get a
    /// complete sentence per operation instead of a fragment.
    package var inProgressTitle: String {
        switch self {
        case .merge: "Merge in progress"
        case .rebase: "Rebase in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        }
    }

    package var continueTitle: String {
        switch self {
        case .merge: "Continue Merge"
        case .rebase: "Continue Rebase"
        case .cherryPick: "Continue Cherry-pick"
        case .revert: "Continue Revert"
        }
    }

    /// Only a rebase replays a sequence of commits, so it alone can skip one.
    package var canSkip: Bool { self == .rebase }
}

/// A merge, rebase, cherry-pick, or revert that Git left half-finished, usually
/// because it hit conflicts. Absent when the repository is in its normal state.
package struct GitOperationState: Equatable, Sendable {
    package let kind: GitOperationKind
    package let reference: String?
    package let step: Int?
    package let total: Int?
    package let conflictedPaths: [String]
    package init(kind: GitOperationKind, reference: String?, step: Int?, total: Int?, conflictedPaths: [String]) { self.kind = kind; self.reference = reference; self.step = step; self.total = total; self.conflictedPaths = conflictedPaths }

    package var hasConflicts: Bool { !conflictedPaths.isEmpty }

    /// Rebase progress as `3/7`, nil for operations that replay a single commit.
    package var progress: String? {
        guard let step, let total, total > 0 else { return nil }
        return "\(step)/\(total)"
    }
}

/// How to resolve a checkout blocked by local changes.
package enum GitCheckoutConflictStrategy: Sendable {
    /// Stash the local changes, switch, then restore them.
    case smart
    /// Switch and discard the local changes.
    case force
}

package enum GitSaveChangesPolicy: String, CaseIterable, Identifiable, Sendable {
    case stash
    case shelve

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .stash: "Git stash"
        case .shelve: "Lithe Shelve"
        }
    }

    package var description: String {
        switch self {
        case .stash: "Store temporary changes in Git's stash list."
        case .shelve: "Store patches in Lithe without adding objects to Git."
        }
    }
}

package enum DiffParser {
    private struct Entry {
        let number: Int
        let text: String
    }

    package static func parse(_ patch: String) -> [DiffRow] {
        parseDocument(patch).rows
    }

    package static func parseDocument(_ patch: String) -> DiffDocument {
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
