import Foundation
import Testing
@testable import Lithe

@Suite("Dependency path selection")
struct DependencyPathSelectionTests {
    @Test
    func multiplePathsAreStoredRelativeToWorkspaceWhenPossible() {
        let workspace = URL(fileURLWithPath: "/example/project", isDirectory: true)
        let sources = workspace.appendingPathComponent("src", isDirectory: true)
        let output = workspace.appendingPathComponent("bin", isDirectory: true)
        let external = URL(fileURLWithPath: "/example/cache/library.jar")

        let result = DependencyPathSelection.appending(
            [sources, output, external],
            to: "src\n/example/project/bin",
            workspaceURL: workspace
        )

        #expect(result.split(separator: "\n").map(String.init) == [
            "src", "/example/project/bin", "/example/cache/library.jar"
        ])
        #expect(DependencyPathSelection.storedPath(for: workspace, workspaceURL: workspace) == ".")
        #expect(DependencyPathSelection.storedPath(
            for: URL(fileURLWithPath: "/example/project-other/src"),
            workspaceURL: workspace
        ) == "/example/project-other/src")
    }

    @Test
    func directoryBrowserOnlyListsImmediateFoldersAndSupportedArchives() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("inner.jar"))
        try Data().write(to: root.appendingPathComponent("dependency.JAR"))
        try Data().write(to: root.appendingPathComponent("README.txt"))

        let directories = try DependencyFolderEntry.contents(of: root, acceptsArchives: false)
        #expect(directories.map(\.url.lastPathComponent) == ["nested"])

        let dependencies = try DependencyFolderEntry.contents(of: root, acceptsArchives: true)
        #expect(dependencies.map(\.url.lastPathComponent) == ["nested", "dependency.JAR"])
    }
}
