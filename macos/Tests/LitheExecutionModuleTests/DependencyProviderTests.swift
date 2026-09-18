import Foundation
import LitheCoreContracts
@testable import LitheExecutionModule
import Testing

struct DependencyProviderTests {
    @Test
    func javaSourceArchiveUsesTheResolvedHomeDirectory() {
        let home = URL(fileURLWithPath: "/opt/jdk-21", isDirectory: true)

        #expect(
            JavaDependencyProvider.sourceArchive(for: home).path
                == "/opt/jdk-21/lib/src.zip"
        )
    }

    @Test
    func javaProviderDeduplicatesAndSortsClasspathByStableKeys() async throws {
        let first = URL(fileURLWithPath: "/workspace/z/lib/core.jar")
        let second = URL(fileURLWithPath: "/workspace/a/lib/core.jar")
        let utility = URL(fileURLWithPath: "/workspace/lib/util.jar")
        let context = DependencyResolutionContext(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            classpath: [first, second, first, utility]
        )

        let graph = try await JavaDependencyProvider().resolve(context: context)

        #expect(graph.roots.map(\.title) == ["core.jar", "core.jar", "util.jar"])
        #expect(graph.roots.map(\.id) == [second.path, first.path, utility.path])
    }
}
