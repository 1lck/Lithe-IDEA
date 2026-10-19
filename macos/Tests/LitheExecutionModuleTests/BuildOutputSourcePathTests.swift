import Foundation
@testable import LitheExecutionModule
import Testing

/// The Build Output opens paths a build tool reported. Core already drops a
/// path whose links leave the workspace; the view rechecks before navigating.
struct BuildOutputSourcePathTests {
    @Test
    func escapingLinksAreRefusedAndInsideLinksKeepTheReportedPath() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory
            .appendingPathComponent("lithe-build-output-path-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        let outside = base.appendingPathComponent("outside")
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(
            at: workspace.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: workspace.appendingPathComponent("src/Inside.swift"))
        try Data("private".utf8).write(to: outside.appendingPathComponent("Secret.swift"))
        try manager.createSymbolicLink(
            at: workspace.appendingPathComponent("alias"),
            withDestinationURL: workspace.appendingPathComponent("src")
        )
        try manager.createSymbolicLink(
            at: workspace.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        #expect(
            BuildOutputSourcePath.url(for: "src/Inside.swift", in: workspace)?.path
                == workspace.appendingPathComponent("src/Inside.swift").path
        )
        // A link that stays inside is kept as the tool reported it.
        #expect(
            BuildOutputSourcePath.url(for: "alias/Inside.swift", in: workspace)?.path
                == workspace.appendingPathComponent("alias/Inside.swift").path
        )
        #expect(BuildOutputSourcePath.url(for: "linked/Secret.swift", in: workspace) == nil)
        // Output text links may also be absolute; they get the same boundary.
        let insideURL = workspace.appendingPathComponent("src/Inside.swift")
        let linkedURL = workspace.appendingPathComponent("linked/Secret.swift")
        let outsideURL = outside.appendingPathComponent("Secret.swift")
        #expect(BuildOutputSourcePath.contains(insideURL, in: workspace))
        #expect(BuildOutputSourcePath.contains(linkedURL, in: workspace) == false)
        #expect(BuildOutputSourcePath.contains(outsideURL, in: workspace) == false)
        // A missing file stays resolvable; the caller checks existence.
        #expect(
            BuildOutputSourcePath.url(for: "src/Missing.swift", in: workspace)?.path
                == workspace.appendingPathComponent("src/Missing.swift").path
        )
    }
}
