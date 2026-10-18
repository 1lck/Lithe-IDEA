import Foundation
import Testing
@testable import Lithe

/// Relative source links in output text belong to the command that wrote the
/// line; a path matching several commands' roots is ambiguous.
@Suite("Output text links")
@MainActor
struct OutputTextViewLinkTests {
    @Test
    func relativeLinksNeedExactlyOneMatchingRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-output-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("a")
        let second = base.appendingPathComponent("b")
        for root in [first, second] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("src"), withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent("src/Same.java"))
        }
        let unique = first.appendingPathComponent("src/Only.java")
        try Data().write(to: unique)
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

        #expect(OutputTextView.resolvePath(
            "src/Same.java", searchRoots: [first, second], requiresUniqueMatch: true, fileExists: exists
        ) == nil)
        #expect(
            OutputTextView.resolvePath(
                "src/Only.java", searchRoots: [first, second], requiresUniqueMatch: true, fileExists: exists
            )?.path == unique.standardizedFileURL.path
        )
        #expect(OutputTextView.resolvePath(
            "src/Only.java", searchRoots: [second], requiresUniqueMatch: true, fileExists: exists
        ) == nil)
        // Single-root callers keep the first-match behavior of the shared view.
        #expect(
            OutputTextView.resolvePath("src/Only.java", searchRoots: [first, second], fileExists: exists)?
                .path == unique.standardizedFileURL.path
        )
    }
}
