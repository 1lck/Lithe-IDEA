import Foundation
import LitheCoreContracts
@testable import LitheExecutionModule
import Testing

struct DependencyProviderTests {
    @Test
    func genericProviderUsesRunServiceIdentityAndPaths() async throws {
        let context = DependencyResolutionContext(
            serviceID: "node:web",
            serviceDisplayName: "Web",
            providerID: "node",
            providerDisplayName: "Node.js",
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            sourceRoots: [URL(fileURLWithPath: "/workspace/apps/web", isDirectory: true)],
            classpath: [URL(fileURLWithPath: "/workspace/build", isDirectory: true)],
            dependencyPaths: DependencyPathConfiguration(
                dependencyPaths: ["node_modules/react"],
                additionalSearchPaths: ["generated/types"]
            )
        )

        let graph = try await RunServiceDependencyProvider().resolve(context: context)
        let service = try #require(graph.roots.first)

        #expect(graph.providerID == "node")
        #expect(service.title == "Web")
        #expect(service.subtitle == "Node.js")
        #expect(service.children.map(\.title) == [
            "Source Code", "Build Outputs", "Dependencies", "Additional Search Paths"
        ])
        #expect(service.children[0].children.map(\.id) == ["/workspace/apps/web"])
        #expect(service.children[1].children.map(\.id) == ["/workspace/build"])
        #expect(service.children[2].children.map(\.id) == ["/workspace/node_modules/react"])
        #expect(service.children[3].children.map(\.id) == ["/workspace/generated/types"])
    }

    @Test
    func genericProviderExcludesDirectoriesAndDescendants() async throws {
        let context = DependencyResolutionContext(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            sourceRoots: [URL(fileURLWithPath: "/workspace/src", isDirectory: true)],
            dependencyPaths: DependencyPathConfiguration(
                additionalSearchPaths: ["build/classes", "build/classes-extra"],
                excludedPaths: ["build/classes"]
            )
        )

        let graph = try await RunServiceDependencyProvider().resolve(context: context)
        let additional = try #require(graph.roots.first?.children.last)
        #expect(additional.children.map(\.id) == ["/workspace/build/classes-extra"])
    }

    @Test
    func providerOwnsDependencyManagementFileMetadata() {
        let provider = RunServiceDependencyProvider()
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let files = [
            root.appendingPathComponent("go.mod"),
            root.appendingPathComponent("go.sum"),
            root.appendingPathComponent("README.md"),
            root.appendingPathComponent("nested/go.mod")
        ]

        #expect(provider.managementFiles(providerID: "go", files: files).map(\.path) == [
            "/workspace/go.mod", "/workspace/go.sum", "/workspace/nested/go.mod"
        ])
        #expect(!provider.manages(root.appendingPathComponent("README.md"), providerID: "go"))
    }

    @Test
    func dependencyPathConfigurationDecodesPartialJson() throws {
        let decoded = try JSONDecoder().decode(
            DependencyPathConfiguration.self,
            from: Data(#"{"sourcePaths":["src/generated"]}"#.utf8)
        )

        #expect(decoded.version == DependencyPathConfiguration.currentVersion)
        #expect(decoded.sourcePaths == ["src/generated"])
        #expect(decoded.dependencyPaths.isEmpty)
    }

    @Test
    func dependencyIndexRoundTripsItsGraph() throws {
        let graph = DependencyGraph(
            providerID: "go",
            serviceID: "go:api",
            roots: [DependencyNode(
                id: "service:go:api",
                title: "Go API",
                subtitle: "Go",
                kind: .group,
                source: .generated
            )]
        )
        let index = DependencyIndex(inputSignature: "test", graph: graph)
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(DependencyIndex.self, from: data)

        #expect(decoded == index)
    }

    @Test
    func virtualDependencyNodeSurvivesIndexRoundTrip() async throws {
        let uri = try #require(URL(string: "plugin-source://package/entry"))
        let context = DependencyResolutionContext(
            serviceID: "plugin:api",
            providerID: "plugin",
            workspaceURL: URL(fileURLWithPath: "/workspace"),
            virtualDocuments: [.init(title: "entry", uri: uri)]
        )
        let graph = try await RunServiceDependencyProvider().resolve(context: context)
        let index = DependencyIndex(inputSignature: "inputs", graph: graph)
        let decoded = try JSONDecoder().decode(DependencyIndex.self, from: JSONEncoder().encode(index))
        #expect(decoded.graph.roots.first?.children[2].children.first?.source == .virtualDocument(uri))
    }
}
