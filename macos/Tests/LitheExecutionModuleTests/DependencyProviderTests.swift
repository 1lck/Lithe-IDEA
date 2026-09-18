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
    func javaProviderGroupsResolvedAndConfiguredPaths() async throws {
        let binary = URL(fileURLWithPath: "/workspace/target/classes", isDirectory: true)
        let first = URL(fileURLWithPath: "/workspace/z/lib/core.jar")
        let second = URL(fileURLWithPath: "/workspace/a/lib/core.jar")
        let source = URL(fileURLWithPath: "/workspace/src/main/java", isDirectory: true)
        let context = DependencyResolutionContext(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            sourceRoots: [source],
            classpath: [binary, first, second, first],
            javaDependencyPaths: JavaDependencyPathConfiguration(
                sourcePaths: ["generated/sources"],
                binaryPaths: ["out/classes"],
                mavenPaths: ["/external/m2/repository"],
                additionalSearchPaths: ["vendor/java"]
            )
        )

        let graph = try await JavaDependencyProvider().resolve(context: context)

        let java = try #require(graph.roots.first)
        #expect(java.title == "Java")
        #expect(java.children.map(\.title) == [
            "Source Code", "bin", "Maven", "Additional Search Paths"
        ])
        #expect(java.children[0].children.map(\.id) == [
            source.path,
            "/workspace/generated/sources"
        ])
        #expect(java.children[1].children.map(\.id) == [
            "/workspace/out/classes",
            binary.path
        ])
        #expect(java.children[2].children.map(\.id) == [
            second.path,
            first.path,
            "/external/m2/repository"
        ])
        #expect(java.children[3].children.map(\.id) == [
            "/workspace/vendor/java"
        ])
    }

    @Test
    func portableConfigurationDecodesWithoutJavaPathField() throws {
        let data = Data(#"{"version":1,"selectedProfiles":["dev"],"customProfiles":[],"skipTests":false}"#.utf8)

        let configuration = try JSONDecoder().decode(
            MavenPortableConfiguration.self,
            from: data
        )

        #expect(configuration.selectedProfiles == ["dev"])
        #expect(configuration.javaDependencyPaths == JavaDependencyPathConfiguration())

        let partialPaths = try JSONDecoder().decode(
            JavaDependencyPathConfiguration.self,
            from: Data(#"{"sourcePaths":["src/generated/java"]}"#.utf8)
        )
        #expect(partialPaths.version == JavaDependencyPathConfiguration.currentVersion)
        #expect(partialPaths.sourcePaths == ["src/generated/java"])
    }
}
