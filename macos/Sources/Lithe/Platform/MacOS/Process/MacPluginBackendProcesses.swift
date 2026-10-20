import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Ends what a plugin backend left running.
///
/// The host starts every plugin backend with its own
/// `LITHE_PLUGIN_BACKEND_SCOPE`, which its descendants inherit even after
/// they call `setsid` or are re-parented. The backend's SDK ends the tools of
/// a call when the call ends; this covers a backend that was killed or
/// crashed before it could. Only processes of this instance's
/// `LITHE_PROCESS_SCOPE` carrying the exact token are signalled, by exact
/// PID and start time.
enum MacPluginBackendProcesses {
    /// The environment entry a backend is started with.
    static func environment(token: String) -> [String: String] {
        [MacProcessScope.pluginBackendEnvironmentKey: token]
    }

    /// Ends every process carrying `token`, off the main actor: `SIGTERM`,
    /// then `SIGKILL` after `gracePeriod`.
    static func end(token: String, gracePeriod: TimeInterval) {
        guard let scope = MacProcessScope.current else { return }
        Task.detached(priority: .utility) {
            let processes = MacProcessScopeScanner.processes(in: scope.id)
            MacProcessScopeScanner.terminate(identities(of: token, in: processes), gracePeriod: gracePeriod)
        }
    }

    static func identities(of token: String, in processes: [MacScopedProcess]) -> [MacProcessIdentity] {
        processes
            .filter { $0.arguments.environment[MacProcessScope.pluginBackendEnvironmentKey] == token }
            .map(\.info.identity)
    }
}
