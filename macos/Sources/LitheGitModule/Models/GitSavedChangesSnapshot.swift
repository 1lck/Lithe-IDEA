import Foundation

/// Immutable, read-only patch contents. Shelf index and worktree versions stay separate.
package struct GitSavedPatchFile: Sendable {
    package let file: GitCommitFile
    package let version: String
    package let base: String
    package let patch: String
    package let document: DiffDocument

    package init(file: GitCommitFile, version: String, base: String, patch: String, document: DiffDocument) {
        self.file = file
        self.version = version
        self.base = base
        self.patch = patch
        self.document = document
    }
}

package struct GitSavedChangesSnapshot: Sendable {
    package let id: String
    package let repositoryRoot: URL
    package let files: [GitSavedPatchFile]

    package var versions: [String] {
        files.reduce(into: []) { if !$0.contains($1.version) { $0.append($1.version) } }
    }

}
