import Foundation

/// Immutable, read-only patch contents. Shelf index and worktree versions stay separate.
package struct GitSavedPatchFile: Sendable {
    package let file: GitCommitFile
    package let version: String
    package let base: String
    package let patch: String
    package let document: DiffDocument

    init(file: GitCommitFile, version: String, base: String, patch: String) {
        self.file = file
        self.version = version
        self.base = base
        self.patch = patch
        document = DiffParser.parseDocument(patch)
    }
}

package struct GitSavedChangesSnapshot: Sendable {
    package let id: String
    package let repositoryRoot: URL
    package let files: [GitSavedPatchFile]

    package var versions: [String] {
        files.reduce(into: []) { if !$0.contains($1.version) { $0.append($1.version) } }
    }

    /// Only frames Git-generated file sections; Core/Git parses and validates paths.
    static func sections(in patch: String) -> [String] {
        var result: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { result.append(String(line)) }
            else if !result.isEmpty { result[result.count - 1] += "\n" + line }
        }
        return result.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }
    }
}
