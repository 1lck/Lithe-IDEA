import Foundation
import LitheModuleAPI
import LitheGitModule

/// Owns operation spans across synchronous Core callbacks, including concurrent Git requests.
final class MacGitLifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: (any LogSink)?
    private var requests: [String: VcsGitRequestSpan] = [:]
    private var commands: [String: VcsGitCommandSpan] = [:]
    init(sink: (any LogSink)?) { self.sink = sink }
    @discardableResult
    func receive(_ event: GitExecutionEvent) -> LogRecordReference? {
        guard let sink, let provider = LogSegment("git") else { return nil }
        return lock.withLock { () -> LogRecordReference? in
            let key = event.operationId
            let commandKey = key + ":" + String(event.invocationId ?? 0)
            let failed = event.error != nil || (event.exitCode ?? 0) != 0
            let failureCode = event.error?.code ?? "process_failed"
            let error = LogFailure(domain: "git.core", code: failureCode)
            // Only fixed known Git subcommands enter the token; argv and user references stay in the console.
            let knownCommands: Set<String> = ["fetch", "push", "pull", "clone", "status", "diff", "log", "show", "config", "rev-parse", "for-each-ref", "worktree", "checkout", "switch", "commit", "reset", "rebase", "merge", "cherry-pick", "stash", "tag", "branch", "remote", "ls-files", "ls-tree", "cat-file", "add", "rm", "restore", "init", "symbolic-ref", "update-ref", "merge-base", "check-ignore", "reflog", "apply", "cherry", "describe", "version"]
            let command = event.arguments?.first(where: { knownCommands.contains($0) }) ?? "git"
            switch event.type {
            case "requestStarted":
                guard requests.count < 256 else { return nil }
                requests[key] = VcsGitRequestSpan.begin(command: command, provider: provider, operationID: key, emit: sink.emit)
            case "started":
                guard commands.count < 256 else { return nil }
                commands[commandKey] = VcsGitCommandSpan.begin(command: command, provider: provider, operationID: key, emit: sink.emit)
            case "finished":
                guard var span = commands.removeValue(forKey: commandKey) else { return nil }
                if failed && event.expectedExit != true {
                    return span.fail(error, exitCode: event.exitCode.map(Int64.init), failureCode: failureCode)
                } else { span.finish(exitCode: event.exitCode.map(Int64.init)) }
            case "requestFinished":
                guard var span = requests.removeValue(forKey: key) else { return nil }
                if failed { return span.fail(error, exitCode: event.exitCode.map(Int64.init), failureCode: failureCode) }
                else { span.finish(exitCode: event.exitCode.map(Int64.init)) }
            default: break
            }
            return nil
        }
    }
}
