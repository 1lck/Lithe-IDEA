import Foundation

/// Resolves the source paths a build tool reported through the host decode
/// commands, for Build Output navigation.
///
/// Core already drops a path whose links leave the workspace. The view is the
/// last place before opening a file, so it checks the real path again: a link
/// that stays inside keeps its workspace-relative form, a link that resolves
/// outside is refused, and a path that does not exist stays resolvable because
/// the caller checks existence before opening it.
package enum BuildOutputSourcePath {
    /// File URL of `relativePath` under `workspaceURL`, or `nil` when
    /// resolving links leaves the workspace.
    package static func url(for relativePath: String, in workspaceURL: URL) -> URL? {
        let candidate = workspaceURL.appendingPathComponent(relativePath).standardizedFileURL
        return contains(candidate, in: workspaceURL) ? candidate : nil
    }

    /// Whether `url`, after resolving links, names a file inside
    /// `workspaceURL`. Text the build tool printed goes through the same
    /// check as decoded diagnostics before it becomes a clickable link.
    package static func contains(_ url: URL, in workspaceURL: URL) -> Bool {
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return resolved.path == root.path || resolved.path.hasPrefix(rootPrefix)
    }
}
