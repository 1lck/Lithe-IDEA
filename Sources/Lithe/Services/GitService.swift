import Foundation

struct GitService: Sendable {
    private let reviewContextLines = "80"
    private let commandRunner: any GitCommandRunner
    private let fileOperations: any WorkspaceFileOperations

    init(
        commandRunner: any GitCommandRunner,
        fileOperations: any WorkspaceFileOperations
    ) {
        self.commandRunner = commandRunner
        self.fileOperations = fileOperations
    }

    struct CommandResult: Sendable {
        let output: String
        let exitCode: Int32

        var succeeded: Bool { exitCode == 0 }
    }

    func snapshot(for workspace: URL) async -> GitSnapshot? {
        await Task.detached(priority: .utility) {
            guard let repositoryPath = run(at: workspace, arguments: ["rev-parse", "--show-toplevel"]).successfulOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !repositoryPath.isEmpty else { return nil }

            let repositoryRoot = URL(fileURLWithPath: repositoryPath)
            let branch = run(at: repositoryRoot, arguments: ["branch", "--show-current"]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = run(
                at: repositoryRoot,
                arguments: ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"]
            ).output
            return GitSnapshot(
                repositoryRoot: repositoryRoot,
                branch: branch.isEmpty ? "detached" : branch,
                changes: parseStatus(status, root: repositoryRoot)
            )
        }.value
    }

    func diff(for change: GitChange) async -> [DiffRow] {
        (await diffDocument(for: change)).rows
    }

    func diffDocument(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> DiffDocument {
        await Task.detached(priority: .userInitiated) {
            DiffParser.parseDocument(patch(for: change, whitespace: whitespace))
        }.value
    }

    func stage(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: change.repositoryRoot, arguments: ["add", "-A", "--"] + change.pathspecs)
        }.value
    }

    func unstage(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let restore = run(at: change.repositoryRoot, arguments: ["restore", "--staged", "--"] + change.pathspecs)
            if restore.succeeded { return restore }
            return run(at: change.repositoryRoot, arguments: ["reset", "HEAD", "--"] + change.pathspecs)
        }.value
    }

    func discard(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            if change.isUntracked {
                do {
                    try fileOperations.removeItem(at: change.url)
                    return CommandResult(output: "", exitCode: 0)
                } catch {
                    return CommandResult(output: error.localizedDescription, exitCode: 1)
                }
            }
            return run(at: change.repositoryRoot, arguments: ["restore", "--worktree", "--"] + change.pathspecs)
        }.value
    }

    func stage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await apply(hunk.patch, at: change.repositoryRoot, arguments: ["apply", "--cached", "--whitespace=nowarn"])
    }

    func unstage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await apply(
            hunk.patch,
            at: change.repositoryRoot,
            arguments: ["apply", "--cached", "--reverse", "--whitespace=nowarn"]
        )
    }

    func discard(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await apply(
            hunk.patch,
            at: change.repositoryRoot,
            arguments: ["apply", "--reverse", "--whitespace=nowarn"]
        )
    }

    func commit(at repositoryRoot: URL, message: String, amend: Bool = false) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            var arguments = ["commit"]
            if amend { arguments.append("--amend") }
            arguments += ["-m", message]
            return run(at: repositoryRoot, arguments: arguments)
        }.value
    }

    func cherryPick(_ hash: String, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["cherry-pick", hash])
        }.value
    }

    func revert(_ hash: String, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["revert", "--no-edit", hash])
        }.value
    }

    func resetCurrentBranch(
        to hash: String,
        at repositoryRoot: URL,
        mode: String = "--mixed"
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            guard ["--soft", "--mixed", "--hard"].contains(mode) else {
                return CommandResult(output: "Unsupported reset mode", exitCode: 1)
            }
            return run(at: repositoryRoot, arguments: ["reset", mode, hash])
        }.value
    }

    func history(
        at repositoryRoot: URL,
        reference: GitReference? = nil,
        limit: Int = 300
    ) async -> GitHistorySnapshot {
        await Task.detached(priority: .utility) {
            let referenceOutput = run(
                at: repositoryRoot,
                arguments: [
                    "for-each-ref",
                    "--sort=refname",
                    "--format=%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)",
                    "refs/heads",
                    "refs/remotes",
                    "refs/tags"
                ]
            ).output

            let references = referenceOutput
                .split(separator: "\n")
                .compactMap { rawLine -> GitReference? in
                    let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard columns.count >= 4 else { return nil }
                    let fullName = columns[0]
                    let kind: GitReferenceKind
                    if fullName.hasPrefix("refs/heads/") {
                        kind = .local
                    } else if fullName.hasPrefix("refs/remotes/") {
                        kind = .remote
                    } else {
                        kind = .tag
                    }
                    guard !columns[1].hasSuffix("/HEAD") else { return nil }
                    return GitReference(
                        fullName: fullName,
                        shortName: columns[1],
                        kind: kind,
                        isCurrent: columns[2].trimmingCharacters(in: .whitespaces) == "*",
                        upstreamShortName: columns[3].isEmpty ? nil : columns[3]
                    )
                }

            var arguments = ["log"]
            if let reference {
                arguments.append(reference.fullName)
            } else {
                arguments.append("--all")
            }
            arguments += [
                "--topo-order",
                "--decorate=short",
                "-n", "\(max(1, limit) + 1)",
                "--date=format:%Y/%m/%d %H:%M",
                "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D"
            ]

            let allCommits = run(at: repositoryRoot, arguments: arguments).output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap(parseCommit)
            let resolvedLimit = max(1, limit)
            let commits = Array(allCommits.prefix(resolvedLimit))

            return GitHistorySnapshot(
                references: references,
                commits: commits,
                hasMore: allCommits.count > resolvedLimit
            )
        }.value
    }

    func files(in commit: GitCommit, at repositoryRoot: URL) async -> [GitCommitFile] {
        await Task.detached(priority: .utility) {
            run(
                at: repositoryRoot,
                arguments: ["-c", "core.quotepath=false", "show", "--pretty=format:", "--name-status", "--find-renames", commit.hash]
            ).output
                .split(separator: "\n")
                .compactMap { rawLine -> GitCommitFile? in
                    let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard columns.count >= 2 else { return nil }
                    let path = columns.last ?? ""
                    guard !path.isEmpty else { return nil }
                    return GitCommitFile(status: columns[0], path: path)
                }
        }.value
    }

    func diffDocument(
        for commit: GitCommit,
        file: GitCommitFile,
        at repositoryRoot: URL,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> DiffDocument {
        await Task.detached(priority: .userInitiated) {
            var arguments = [
                "-c", "core.quotepath=false",
                "show",
                "--format=",
                "--no-ext-diff"
            ]
            if whitespace == .ignoreAllWhitespace {
                arguments.append("--ignore-all-space")
            }
            arguments += [
                "--unified=80",
                commit.hash,
                "--",
                file.path
            ]
            let patch = run(at: repositoryRoot, arguments: arguments).output
            return DiffParser.parseDocument(patch)
        }.value
    }

    func blame(fileURL: URL, at repositoryRoot: URL) async -> [GitBlameLine] {
        await Task.detached(priority: .utility) {
            let rootPath = repositoryRoot.standardizedFileURL.path
            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { return [] }
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            let output = run(
                at: repositoryRoot,
                arguments: ["blame", "--line-porcelain", "--", relativePath]
            ).output

            var result: [GitBlameLine] = []
            var commitHash = ""
            var authorName = "Unknown"
            var authorTime: TimeInterval = 0
            var finalLine = 0
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy/M/d"

            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let columns = line.split(separator: " ")
                if columns.count >= 3, columns[0].count == 40,
                   let parsedLine = Int(columns[2]) {
                    commitHash = String(columns[0])
                    finalLine = parsedLine
                } else if line.hasPrefix("author ") {
                    authorName = String(line.dropFirst(7))
                } else if line.hasPrefix("author-time ") {
                    authorTime = TimeInterval(line.dropFirst(12)) ?? 0
                } else if line.hasPrefix("\t"), finalLine > 0 {
                    let date = authorTime > 0
                        ? dateFormatter.string(from: Date(timeIntervalSince1970: authorTime))
                        : "Working tree"
                    result.append(GitBlameLine(
                        line: finalLine - 1,
                        commitHash: commitHash,
                        authorName: authorName,
                        date: date
                    ))
                    finalLine += 1
                }
            }
            return result
        }.value
    }

    func commit(withHash hash: String, at repositoryRoot: URL) async -> GitCommit? {
        await Task.detached(priority: .utility) {
            let output = run(
                at: repositoryRoot,
                arguments: [
                    "show", "-s",
                    "--date=format:%Y/%m/%d %H:%M",
                    "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D",
                    hash
                ]
            ).output
            return output.split(separator: "\n", omittingEmptySubsequences: true).first.flatMap(parseCommit)
        }.value
    }

    func comparisonWithWorkingTree(
        for reference: GitReference,
        at repositoryRoot: URL
    ) async -> GitBranchComparison {
        await Task.detached(priority: .userInitiated) {
            let output = run(
                at: repositoryRoot,
                arguments: [
                    "-c", "core.quotepath=false",
                    "diff", "--name-status", "--find-renames", reference.fullName, "--"
                ]
            ).output
            let files = output
                .split(separator: "\n")
                .compactMap { rawLine -> GitBranchComparisonFile? in
                    let columns = rawLine
                        .split(separator: "\t", omittingEmptySubsequences: false)
                        .map(String.init)
                    guard columns.count >= 2 else { return nil }
                    let path = columns.last ?? ""
                    guard !path.isEmpty else { return nil }
                    return GitBranchComparisonFile(status: columns[0], path: path)
                }
            return GitBranchComparison(reference: reference, files: files)
        }.value
    }

    func diff(
        for file: GitBranchComparisonFile,
        against reference: GitReference,
        at repositoryRoot: URL
    ) async -> [DiffRow] {
        await Task.detached(priority: .userInitiated) {
            let patch = run(
                at: repositoryRoot,
                arguments: [
                    "diff", "--no-ext-diff", "--unified=\(reviewContextLines)",
                    reference.fullName, "--", file.path
                ]
            ).output
            return DiffParser.parse(patch)
        }.value
    }

    func createBranch(
        named name: String,
        from reference: GitReference,
        checkout: Bool,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let validation = run(at: repositoryRoot, arguments: ["check-ref-format", "--branch", name])
            guard validation.succeeded else { return validation }
            if checkout {
                return run(at: repositoryRoot, arguments: ["switch", "-c", name, reference.fullName])
            }
            return run(at: repositoryRoot, arguments: ["branch", name, reference.fullName])
        }.value
    }

    func renameBranch(
        _ reference: GitReference,
        to newName: String,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let validation = run(at: repositoryRoot, arguments: ["check-ref-format", "--branch", newName])
            guard validation.succeeded else { return validation }
            if reference.isCurrent {
                return run(at: repositoryRoot, arguments: ["branch", "-m", newName])
            }
            return run(at: repositoryRoot, arguments: ["branch", "-m", reference.shortName, newName])
        }.value
    }

    func deleteBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            guard reference.kind == .local, !reference.isCurrent else {
                return CommandResult(output: "Only a non-current local branch can be deleted", exitCode: 1)
            }
            return run(at: repositoryRoot, arguments: ["branch", "-d", reference.shortName])
        }.value
    }

    func mergeBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            guard !reference.isCurrent else {
                return CommandResult(output: "The current branch cannot be merged into itself", exitCode: 1)
            }
            return run(at: repositoryRoot, arguments: ["merge", "--no-edit", reference.fullName])
        }.value
    }

    func rebaseCurrentBranch(onto reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            guard !reference.isCurrent else {
                return CommandResult(output: "The current branch cannot be rebased onto itself", exitCode: 1)
            }
            return run(at: repositoryRoot, arguments: ["rebase", reference.fullName])
        }.value
    }

    func updateCurrentBranch(at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["pull", "--ff-only"])
        }.value
    }

    func fetch(at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["fetch", "--all", "--prune"])
        }.value
    }

    func checkout(
        _ reference: GitReference,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            switch reference.kind {
            case .local:
                return run(at: repositoryRoot, arguments: ["switch", reference.shortName])
            case .tag:
                return run(at: repositoryRoot, arguments: ["switch", "--detach", reference.fullName])
            case .remote:
                let remotePath = reference.fullName.replacingOccurrences(of: "refs/remotes/", with: "")
                let components = remotePath.split(separator: "/", maxSplits: 1).map(String.init)
                guard components.count == 2 else {
                    return CommandResult(output: "Invalid remote branch name", exitCode: 1)
                }
                let localName = components[1]
                let existingLocal = run(
                    at: repositoryRoot,
                    arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(localName)"]
                )
                if existingLocal.succeeded {
                    return run(at: repositoryRoot, arguments: ["switch", localName])
                }
                return run(
                    at: repositoryRoot,
                    arguments: ["switch", "--track", "-c", localName, reference.fullName]
                )
            }
        }.value
    }

    func checkoutRevision(
        _ rawRevision: String,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let revision = rawRevision.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !revision.isEmpty else {
                return CommandResult(output: "Enter a tag, branch, or revision", exitCode: 1)
            }
            let validation = run(
                at: repositoryRoot,
                arguments: ["rev-parse", "--verify", "\(revision)^{commit}"]
            )
            guard validation.succeeded else { return validation }
            return run(at: repositoryRoot, arguments: ["switch", "--detach", revision])
        }.value
    }

    func push(
        _ reference: GitReference,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let upstream = run(
                at: repositoryRoot,
                arguments: ["rev-parse", "--abbrev-ref", "\(reference.shortName)@{upstream}"]
            )
            if upstream.succeeded, reference.isCurrent {
                return run(at: repositoryRoot, arguments: ["push"])
            }
            if upstream.succeeded {
                let trackingName = upstream.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let separator = trackingName.firstIndex(of: "/") {
                    let remote = String(trackingName[..<separator])
                    let remoteBranch = String(trackingName[trackingName.index(after: separator)...])
                    return run(
                        at: repositoryRoot,
                        arguments: ["push", remote, "\(reference.shortName):\(remoteBranch)"]
                    )
                }
            }

            let remotes = run(at: repositoryRoot, arguments: ["remote"]).output
                .split(separator: "\n")
                .map(String.init)
            guard let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
                return CommandResult(output: "No Git remote is configured", exitCode: 1)
            }
            return run(
                at: repositoryRoot,
                arguments: ["push", "--set-upstream", remote, reference.shortName]
            )
        }.value
    }

    func cloneRepository(
        from remote: String,
        to destination: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let parent = destination.deletingLastPathComponent()
            guard fileOperations.fileExists(at: parent) else {
                return CommandResult(output: "The destination folder does not exist", exitCode: 1)
            }
            return run(
                at: parent,
                arguments: ["clone", "--", remote, destination.path]
            )
        }.value
    }

    func stashes(at repositoryRoot: URL) async -> [GitStash] {
        await Task.detached(priority: .utility) {
            let output = run(
                at: repositoryRoot,
                arguments: [
                    "stash", "list",
                    "--date=iso",
                    "--pretty=format:%gd%x1f%gs%x1f%ad"
                ]
            ).output
            return output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    let columns = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                        .map(String.init)
                    guard columns.count >= 3 else { return nil }
                    let reference = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let subject = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reference.isEmpty else { return nil }
                    let branch: String?
                    let branchMarker = subject.range(of: "On ", options: .caseInsensitive)
                        ?? subject.range(of: " on ", options: .caseInsensitive)
                    if let start = branchMarker {
                        let branchAndMessage = subject[start.upperBound...]
                        let branchPart = branchAndMessage.split(
                            maxSplits: 1,
                            omittingEmptySubsequences: true,
                            whereSeparator: { $0 == ":" || $0 == "," }
                        ).first
                        let rawBranch = branchPart.map(String.init)
                        branch = rawBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        branch = nil
                    }
                    let message: String
                    if let start = branchMarker,
                       let separator = subject[start.upperBound...].firstIndex(of: ":") {
                        message = String(subject[subject.index(after: separator)...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let separator = subject.firstIndex(of: ":") {
                        message = String(subject[subject.index(after: separator)...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        message = subject
                    }
                    return GitStash(
                        reference: reference,
                        message: message,
                        branch: branch,
                        date: columns[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
        }.value
    }

    func stash(
        message: String,
        includeUntracked: Bool,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            var arguments = ["stash", "push"]
            if includeUntracked {
                arguments.append("--include-untracked")
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedMessage.isEmpty {
                arguments += ["-m", normalizedMessage]
            }
            return run(at: repositoryRoot, arguments: arguments)
        }.value
    }

    func applyStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["stash", "apply", stash.reference])
        }.value
    }

    func popStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["stash", "pop", stash.reference])
        }.value
    }

    func dropStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["stash", "drop", stash.reference])
        }.value
    }

    func stageAll(at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["add", "--all"])
        }.value
    }

    private func parseStatus(_ output: String, root: URL) -> [GitChange] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [GitChange] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            let characters = Array(field)
            guard characters.count >= 4 else {
                index += 1
                continue
            }
            let indexStatus = characters[0]
            let workTreeStatus = characters[1]
            let path = String(characters.dropFirst(3))
            let isRenameOrCopy = indexStatus == "R" || indexStatus == "C" || workTreeStatus == "R" || workTreeStatus == "C"
            let originalPath = isRenameOrCopy && index + 1 < fields.count ? fields[index + 1] : nil
            changes.append(GitChange(
                repositoryRoot: root,
                path: path,
                originalPath: originalPath,
                indexStatus: indexStatus,
                workTreeStatus: workTreeStatus
            ))
            index += isRenameOrCopy ? 2 : 1
        }
        return changes
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func parseCommit(_ rawLine: Substring) -> GitCommit? {
        let columns = rawLine.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard columns.count >= 8 else { return nil }
        return GitCommit(
            hash: columns[0],
            shortHash: columns[1],
            parentHashes: columns[2].split(separator: " ").map(String.init),
            authorName: columns[3],
            authorEmail: columns[4],
            date: columns[5],
            subject: columns[6],
            decorations: columns[7]
        )
    }

    private func patch(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode
    ) -> String {
        let whitespaceArguments = whitespace == .ignoreAllWhitespace
            ? ["--ignore-all-space"]
            : []
        if change.isUntracked {
            return run(
                at: change.repositoryRoot,
                arguments: ["diff", "--no-index"] + whitespaceArguments +
                    ["--unified=\(reviewContextLines)", "--", "/dev/null", change.path]
            ).output
        }
        if change.hasWorkingTreeChange {
            return run(
                at: change.repositoryRoot,
                arguments: ["diff", "--no-ext-diff"] + whitespaceArguments +
                    ["--unified=\(reviewContextLines)", "--"] + change.pathspecs
            ).output
        }
        return run(
            at: change.repositoryRoot,
            arguments: ["diff", "--cached", "--no-ext-diff"] + whitespaceArguments +
                ["--unified=\(reviewContextLines)", "--"] + change.pathspecs
        ).output
    }

    private func apply(
        _ patch: String,
        at directory: URL,
        arguments: [String]
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: directory, arguments: arguments, input: patch)
        }.value
    }

    private func run(
        at directory: URL,
        arguments: [String],
        input: String? = nil
    ) -> CommandResult {
        let result = commandRunner.run(
            arguments: arguments,
            workingDirectory: directory.path,
            input: input
        )
        return CommandResult(output: result.output, exitCode: result.exitCode)
    }
}

private extension GitService.CommandResult {
    var successfulOutput: String? { succeeded ? output : nil }
}
