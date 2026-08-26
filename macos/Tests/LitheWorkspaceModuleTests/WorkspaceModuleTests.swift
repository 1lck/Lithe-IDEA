import Foundation
import LitheApplicationKernel
@testable import LitheWorkspaceModule
import LitheModuleAPI
import Testing

@MainActor
struct WorkspaceModuleTests {
    @Test
    func eagerWorkspaceCreatesGraphOnlyWhenActivated() async throws {
        let calls = Counter()
        let runtime = ModuleRuntime()
        try runtime.register(ModuleFactory(manifest: WorkspaceFoundationModule.moduleManifest) {
            calls.factory += 1
            return WorkspaceFoundationModule(makeGraph: {
                calls.graph += 1
                return TestGraph()
            })
        })
        #expect(calls.factory == 0)
        _ = try await runtime.activateCapability(.workspaceFoundation)
        #expect(calls.factory == 1)
        #expect(calls.graph == 1)
    }

    @Test
    func shutdownReleasesWorkspaceGraphAndResource() async throws {
        let calls = Counter()
        let runtime = ModuleRuntime()
        try runtime.register(ModuleFactory(manifest: WorkspaceFoundationModule.moduleManifest) {
            calls.factory += 1
            return WorkspaceFoundationModule(makeGraph: {
                calls.graph += 1
                let graph = TestGraph()
                calls.latest = graph
                return graph
            })
        })
        _ = try await runtime.activateCapability(.workspaceFoundation)
        weak var released = calls.latest
        try await runtime.shutdown(.workspace)
        #expect(released == nil)
        #expect(runtime.capability(.workspaceFoundation) == nil)
        #expect(try runtime.snapshot(for: .workspace).activity.activeResourceCount == 0)
    }
}

@MainActor private final class Counter {
    var factory = 0
    var graph = 0
    weak var latest: TestGraph?
}
@MainActor private final class TestGraph: WorkspaceResourceGraph {
    var hasActiveResources = false
    var feature: WorkspaceFeatureModel?
    func attach(workspaceProjection: WorkspaceFeatureModel) { feature = workspaceProjection }
    func stop() async {}
}
