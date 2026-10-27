import Foundation
import LitheCoreContracts

// Note: 运行启动 PATH 的取舍见 .agents/notes/implemented/bug-fix/2026-10-25-run-launch-path-for-node-launchers.md

/// Composes the environment for a run process that Lithe starts by absolute
/// path.
///
/// A Lithe opened from Finder inherits launchd's minimal `PATH`, while the
/// tools Lithe resolves can live in Homebrew or a Node version manager
/// directory. Package managers and `node_modules/.bin` launchers start their
/// interpreter through an `env`-based shebang, so the child still needs the
/// interpreter directory on `PATH` even though the launcher itself is started
/// by absolute path.
///
/// Windows already prepends the selected runtime directories and the resolved
/// executable's directory in `windows/tauri/src-tauri/src/run.rs`; this keeps
/// both products' launch environments equivalent.
enum RunLaunchEnvironment {
    /// Appends the discovered interpreter directory and the resolved
    /// executable's directory to the existing entries, which keep their
    /// priority: a run configuration that sets `PATH` may pin its own
    /// toolchain, and the default Finder environment contains no `node`, so
    /// the appended directories are reached in both cases. Entries are
    /// deduplicated by exact spelling so case-sensitive volumes remain valid.
    ///
    /// Project-owned interpreters and launchers are never promoted: an
    /// untrusted repository must not capture the interpreter of every script
    /// the user launches, and putting a project root on `PATH` would let
    /// repository files shadow system tools.
    static func augmenting(
        _ environment: [String: String],
        executableURL: URL,
        nodeCandidates: [RuntimeToolCandidate],
        projectURL: URL,
        defaultSearchPath: String? = nil
    ) -> [String: String] {
        var resolvedDirectories: [String] = []
        if let node = nodeCandidates.first(where: {
            $0.source != .project && !isInsideProject($0.executableURL, projectURL: projectURL)
        }) {
            resolvedDirectories.append(node.executableURL.deletingLastPathComponent().path)
        }
        if !isInsideProject(executableURL, projectURL: projectURL) {
            resolvedDirectories.append(executableURL.deletingLastPathComponent().path)
        }
        guard !resolvedDirectories.isEmpty else { return environment }

        // Only the platform adapter knows the system fallback; an explicitly empty PATH wins.
        let existingDirectories = (environment["PATH"] ?? defaultSearchPath ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let directories = (existingDirectories + resolvedDirectories).filter {
            seen.insert($0).inserted
        }

        var result = environment
        result["PATH"] = directories.joined(separator: ":")
        return result
    }

    private static func isInsideProject(_ url: URL, projectURL: URL) -> Bool {
        let root = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        // A project of `/` would make every absolute path project-owned; no
        // product flow opens that as a workspace, but the guard keeps the
        // containment check total.
        guard root != "/" else { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(prefix)
    }
}
