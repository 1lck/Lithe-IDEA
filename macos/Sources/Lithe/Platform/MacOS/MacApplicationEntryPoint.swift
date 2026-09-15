import Foundation
import LitheRustCore

/// AskPass reuses the signed application binary and exits before constructing UI state.
@main
enum MacApplicationEntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--lithe-git-askpass" {
            let prompt = CommandLine.arguments.dropFirst(2).first ?? "Git authentication"
            exit(prompt.withCString { lithe_bridge_git_askpass($0) })
        }
        // OpenSSH executes SSH_ASKPASS as a path, without shell arguments.
        if ProcessInfo.processInfo.environment["LITHE_GIT_ASKPASS_MODE"] == "1", CommandLine.arguments.count == 2 {
            exit(CommandLine.arguments[1].withCString { lithe_bridge_git_askpass($0) })
        }
        LitheApp.main()
    }
}
