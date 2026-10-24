import Foundation
import LitheCoreContracts

/// Starts the official login command in the background. A login shell supplies
/// the user's own PATH, so the CLI they installed is the one that runs.
struct MacAgentAccountSignIn: AgentAccountSigningIn {
    /// One account sign-in: the official command and the variable selecting its directory.
    private struct Command {
        let line: String
        let directoryVariable: String
    }

    private static let timeoutMilliseconds = 5 * 60 * 1_000

    let runner: any ProcessRunner

    func signIn(agentID: String, directory: URL) async throws {
        let command: Command
        switch agentID {
        case "claude-acp": command = Command(line: "claude auth login --claudeai", directoryVariable: "CLAUDE_CONFIG_DIR")
        case "codex-acp": command = Command(line: "codex login", directoryVariable: "CODEX_HOME")
        default: throw AgentAccountSignInError.unsupported
        }
        var environment = ProcessInfo.processInfo.environment
        environment[command.directoryVariable] = directory.path
        let request = ProcessRequest(
            executablePath: "/bin/zsh",
            arguments: ["-l", "-i", "-c", command.line],
            workingDirectory: NSHomeDirectory(),
            environment: environment,
            timeoutMilliseconds: Self.timeoutMilliseconds
        )
        let runner = runner
        // The runner polls its own task for cancellation, so run it in a task
        // that this call's cancellation can cancel.
        let task = Task.detached(priority: .userInitiated) { runner.run(request) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        switch result.exitCode {
        case 0: return
        case 124: throw AgentAccountSignInError.timedOut
        default: throw AgentAccountSignInError.failed
        }
    }
}
