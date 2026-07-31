import Foundation

enum GitService {
    private static let reviewContextLines = "80"

    struct CommandResult: Sendable {
        let output: String
        let exitCode: Int32

        var succeeded: Bool { exitCode == 0 }
    }

    static func snapshot(for workspace: URL) async -> GitSnapshot? {
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

    static func diff(for change: GitChange) async -> [DiffRow] {
        (await diffDocument(for: change)).rows
    }

    static func diffDocument(for change: GitChange) async -> DiffDocument {
        await Task.detached(priority: .userInitiated) {
            DiffParser.parseDocument(patch(for: change))
        }.value
    }

    static func stage(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: change.repositoryRoot, arguments: ["add", "-A", "--"] + change.pathspecs)
        }.value
    }

    static func unstage(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let restore = run(at: change.repositoryRoot, arguments: ["restore", "--staged", "--"] + change.pathspecs)
            if restore.succeeded { return restore }
            return run(at: change.repositoryRoot, arguments: ["reset", "HEAD", "--"] + change.pathspecs)
        }.value
    }

    static func discard(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            if change.isUntracked {
                do {
                    try FileManager.default.removeItem(at: change.url)
                    return CommandResult(output: "", exitCode: 0)
                } catch {
                    return CommandResult(output: error.localizedDescription, exitCode: 1)
                }
            }
            return run(at: change.repositoryRoot, arguments: ["restore", "--worktree", "--"] + change.pathspecs)
        }.value
    }

    static func stage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await apply(hunk.patch, at: change.repositoryRoot, arguments: ["apply", "--cached", "--whitespace=nowarn"])
    }

    static func unstage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await apply(
            hunk.patch,
            at: change.repositoryRoot,
            arguments: ["apply", "--cached", "--reverse", "--whitespace=nowarn"]
        )
    }

    static func discard(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await apply(
            hunk.patch,
            at: change.repositoryRoot,
            arguments: ["apply", "--reverse", "--whitespace=nowarn"]
        )
    }

    static func commit(at repositoryRoot: URL, message: String, amend: Bool = false) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            var arguments = ["commit"]
            if amend { arguments.append("--amend") }
            arguments += ["-m", message]
            return run(at: repositoryRoot, arguments: arguments)
        }.value
    }

    static func history(at repositoryRoot: URL, reference: GitReference? = nil) async -> GitHistorySnapshot {
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
                "-n", "150",
                "--date=format:%Y/%m/%d %H:%M",
                "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D"
            ]

            let commits = run(at: repositoryRoot, arguments: arguments).output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap(parseCommit)

            return GitHistorySnapshot(references: references, commits: commits)
        }.value
    }

    static func files(in commit: GitCommit, at repositoryRoot: URL) async -> [GitCommitFile] {
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

    static func blame(fileURL: URL, at repositoryRoot: URL) async -> [GitBlameLine] {
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

    static func commit(withHash hash: String, at repositoryRoot: URL) async -> GitCommit? {
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

    static func comparisonWithWorkingTree(
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

    static func diff(
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

    static func createBranch(
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

    static func renameBranch(
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

    static func updateCurrentBranch(at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["pull", "--ff-only"])
        }.value
    }

    static func checkout(
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

    static func checkoutRevision(
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

    static func push(
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

    static func stageAll(at repositoryRoot: URL) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["add", "--all"])
        }.value
    }

    private static func parseStatus(_ output: String, root: URL) -> [GitChange] {
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

    private static func parseCommit(_ rawLine: Substring) -> GitCommit? {
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

    private static func patch(for change: GitChange) -> String {
        if change.isUntracked {
            return run(
                at: change.repositoryRoot,
                arguments: ["diff", "--no-index", "--unified=\(reviewContextLines)", "--", "/dev/null", change.path]
            ).output
        }
        if change.hasWorkingTreeChange {
            return run(
                at: change.repositoryRoot,
                arguments: ["diff", "--no-ext-diff", "--unified=\(reviewContextLines)", "--"] + change.pathspecs
            ).output
        }
        return run(
            at: change.repositoryRoot,
            arguments: ["diff", "--cached", "--no-ext-diff", "--unified=\(reviewContextLines)", "--"] + change.pathspecs
        ).output
    }

    private static func apply(
        _ patch: String,
        at directory: URL,
        arguments: [String]
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: directory, arguments: arguments, input: patch)
        }.value
    }

    private static func run(
        at directory: URL,
        arguments: [String],
        input: String? = nil
    ) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe

        do {
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            return CommandResult(output: error.localizedDescription, exitCode: 1)
        }
    }
}

private extension GitService.CommandResult {
    var successfulOutput: String? { succeeded ? output : nil }
}
