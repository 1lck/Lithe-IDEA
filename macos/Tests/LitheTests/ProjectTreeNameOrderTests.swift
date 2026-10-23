import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project tree natural name order")
struct ProjectTreeNameOrderTests {
    /// The shared fixture also drives Rust Core's `file_name_order` tests, so the
    /// Core listing, the Swift fallback scan and tree insertion cannot drift apart.
    @Test
    func sharedFixtureGroupsSortStrictlyInTheListedOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/workspace/file-name-order-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(fixture["orderedGroups"] as? [[String: Any]])
        #expect(!groups.isEmpty)
        for group in groups {
            let id = try #require(group["id"] as? String)
            let names = try #require(group["names"] as? [String])
            for (index, earlier) in names.enumerated() {
                for later in names[(index + 1)...] {
                    #expect(NaturalNameOrder.compareFileNames(earlier, later) < 0, "\(id): \(earlier) should precede \(later)")
                    #expect(NaturalNameOrder.compareFileNames(later, earlier) > 0, "\(id): \(later) should follow \(earlier)")
                }
            }
        }
    }

    @Test
    func branchNameOrderKeepsDashAndUnderscoreDistinctFromFileNameOrder() {
        // Refs use NaturalComparator without likeFileNames: '-' stays below '.'.
        let dashed = Array("foo-bar".utf16), dotted = Array("foo.bar".utf16)
        #expect(NaturalNameOrder.compare(dashed, dotted) < 0)
        #expect(NaturalNameOrder.compareFileNames("foo-bar", "foo.bar") > 0)
    }

    @Test
    func fallbackScanListsVersionedNamesByNumberWithDirectoriesFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("zeta/part10"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("zeta/part2"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        for name in ["v0.1.12.md", "v0.1.4.md", "v0.1.14.md", "TEMPLATE.md", "v0.1.13.md", "v0.2.0.md"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let rules = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        let builder = FileSystemWorkspaceSnapshotBuilder()

        let snapshot = try #require(builder.snapshot(at: root, visibilityRules: rules))
        let rootNames = (snapshot.root.children ?? []).map(\.name)
        #expect(rootNames == ["Alpha", "zeta", "TEMPLATE.md", "v0.1.4.md", "v0.1.12.md", "v0.1.13.md", "v0.1.14.md", "v0.2.0.md"])
        let zeta = try #require(snapshot.root.children?.first { $0.name == "zeta" })
        #expect((zeta.children ?? []).map(\.name) == ["part2", "part10"])

        let listed = builder.listDirectories([root], at: root, visibilityRules: rules)
        let listedNames = try #require(listed[root.standardizedFileURL.path]).map { $0.url.lastPathComponent }
        #expect(listedNames == rootNames)
    }

    @Test
    func insertedFilesLandInVersionOrder() throws {
        let root = URL(fileURLWithPath: "/in-memory/release-notes")
        func row(_ name: String) -> FileNode {
            FileNode(url: root.appendingPathComponent(name), isDirectory: false, children: nil)
        }
        var tree = FileNode(url: root, isDirectory: true, children: [row("v0.1.4.md"), row("v0.1.13.md"), row("v0.2.0.md")])
        for name in ["v0.1.5.md", "v0.1.12.md", "TEMPLATE.md"] {
            guard case .updated(let updated) = tree.inserting(file: root.appendingPathComponent(name)) else {
                Issue.record("Inserting \(name) should update the loaded directory")
                return
            }
            tree = updated
        }
        #expect((tree.children ?? []).map(\.name) == [
            "TEMPLATE.md", "v0.1.4.md", "v0.1.5.md", "v0.1.12.md", "v0.1.13.md", "v0.2.0.md",
        ])
    }
}
