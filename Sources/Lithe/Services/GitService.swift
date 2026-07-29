import Foundation

enum GitService {
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
            let status = run(at: repositoryRoot, arguments: ["status", "--porcelain=v1", "--untracked-files=all"]).output
            return GitSnapshot(
                repositoryRoot: repositoryRoot,
                branch: branch.isEmpty ? "detached" : branch,
                changes: parseStatus(status, root: repositoryRoot)
            )
        }.value
    }

    static func diff(for change: GitChange) async -> [DiffRow] {
        await Task.detached(priority: .userInitiated) {
            let patch: String
            if change.isUntracked {
                patch = run(
                    at: change.repositoryRoot,
                    arguments: ["diff", "--no-index", "--unified=3", "--", "/dev/null", change.path]
                ).output
            } else if change.hasWorkingTreeChange {
                patch = run(
                    at: change.repositoryRoot,
                    arguments: ["diff", "--no-ext-diff", "--unified=3", "--", change.path]
                ).output
            } else {
                patch = run(
                    at: change.repositoryRoot,
                    arguments: ["diff", "--cached", "--no-ext-diff", "--unified=3", "--", change.path]
                ).output
            }
            return DiffParser.parse(patch)
        }.value
    }

    static func stage(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: change.repositoryRoot, arguments: ["add", "--", change.path])
        }.value
    }

    static func unstage(_ change: GitChange) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let restore = run(at: change.repositoryRoot, arguments: ["restore", "--staged", "--", change.path])
            if restore.succeeded { return restore }
            return run(at: change.repositoryRoot, arguments: ["reset", "HEAD", "--", change.path])
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
            return run(at: change.repositoryRoot, arguments: ["restore", "--worktree", "--", change.path])
        }.value
    }

    static func commit(at repositoryRoot: URL, message: String) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(at: repositoryRoot, arguments: ["commit", "-m", message])
        }.value
    }

    private static func parseStatus(_ output: String, root: URL) -> [GitChange] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.count >= 4 else { return nil }
            let characters = Array(line)
            let indexStatus = characters[0]
            let workTreeStatus = characters[1]
            var path = String(characters.dropFirst(3))
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }
            if path.hasPrefix("\"") && path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }
            return GitChange(
                repositoryRoot: root,
                path: path,
                indexStatus: indexStatus,
                workTreeStatus: workTreeStatus
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func run(at directory: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
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
