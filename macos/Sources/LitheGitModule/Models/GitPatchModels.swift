import Foundation

package enum GitPatchSource: String, Codable, CaseIterable, Sendable {
    case workingTree, staged, unstaged, commits
}

package enum GitPatchTarget: String, Codable, CaseIterable, Sendable {
    case worktree, indexAndWorktree
}

package struct GitPatchFile: Decodable, Equatable, Sendable, Identifiable {
    package let path: String
    package let originalPath: String?
    package let additions: Int?
    package let deletions: Int?
    package var id: String { path }
}

package struct GitPatchExport: Decodable, Sendable {
    package let patch: String
    package let files: [GitPatchFile]
    package let byteLength: Int
}

package struct GitPatchPreview: Decodable, Sendable {
    package let applicable: Bool
    package let files: [GitPatchFile]
    package let diagnostic: String
    package let expectedState: String?
    package let byteLength: Int
}

package struct GitPatchFailure: Error, LocalizedError, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}

/// The native file boundary rejects oversized or non-UTF-8 input before calling Core.
package enum GitPatchContent {
    package static let maximumByteCount = 32 * 1024 * 1024

    package static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else { throw GitPatchFailure("Patch files must be at most 32 MiB.") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitPatchFailure("The patch must contain valid UTF-8 text. No bytes have been changed.")
        }
        return text
    }
}
