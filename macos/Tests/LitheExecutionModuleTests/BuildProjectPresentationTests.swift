import Foundation
import LitheCoreContracts
@testable import LitheExecutionModule
import Testing

struct BuildProjectPresentationTests {
    private let workspace = URL(fileURLWithPath: "/workspace/demo")

    @Test
    func labelsAndRolesFollowTheDeepestImportedDirectory() throws {
        let model = try importedModel()
        #expect(BuildProjectPresentation.projectName(for: workspace.appendingPathComponent("modules/app/src/Main.java"),
            workspace: workspace, models: [model]) == "Application")
        #expect(BuildProjectPresentation.projectName(for: workspace.appendingPathComponent("modules/app-copy/Main.java"),
            workspace: workspace, models: [model]) == "Reactor")
        #expect(BuildProjectPresentation.sourceRootKind(for: workspace.appendingPathComponent("modules/app/src/checks/Helper.java"),
            workspace: workspace, models: [model]) == "testSource")
        #expect(BuildProjectPresentation.sourceRootKind(for: workspace.appendingPathComponent("modules/app/src/checks-copy/Main.java"),
            workspace: workspace, models: [model]) == "source")
        #expect(BuildProjectPresentation.sourceRootKind(for: workspace.appendingPathComponent("modules/app/build/generated/Fixture.java"),
            workspace: workspace, models: [model]) == "generatedTestSource")
        #expect(BuildProjectPresentation.sourceRootKind(for: workspace.appendingPathComponent("modules/app/test-data/input.json"),
            workspace: workspace, models: [model]) == "testResource")
    }

    @Test
    func outsideWorkspaceAndVirtualDocumentsCannotAcquireAnImportedRole() throws {
        let model = try importedModel()
        let outside = URL(fileURLWithPath: "/workspace/demo-copy/modules/app/src/Main.java")
        #expect(BuildProjectPresentation.projectName(for: outside, workspace: workspace, models: [model]) == nil)
        #expect(BuildProjectPresentation.sourceRootKind(for: outside, workspace: workspace, models: [model]) == nil)
        let virtual = try #require(URL(string: "jdt://contents/demo/Main.java"))
        #expect(BuildProjectPresentation.projectName(for: virtual, workspace: workspace, models: [model]) == nil)
        #expect(BuildProjectPresentation.sourceRootKind(for: virtual, workspace: workspace, models: [model]) == nil)
    }

    private func importedModel() throws -> BuildModel {
        try JSONDecoder().decode(BuildModel.self, from: Data(#"""
        {"projects":[{"id":"root","path":".","name":"Reactor"},
          {"id":"app","path":"modules/app","name":"app","displayName":"Application","parentID":"root"}],
         "contentRoots":[
          {"projectID":"app","path":"modules/app/src","kind":"source"},
          {"projectID":"app","path":"modules/app/src/checks","kind":"testSource"},
          {"projectID":"app","path":"modules/app/build/generated","kind":"generatedTestSource"},
          {"projectID":"app","path":"modules/app/test-data","kind":"testResource"}]}
        """#.utf8))
    }
}
