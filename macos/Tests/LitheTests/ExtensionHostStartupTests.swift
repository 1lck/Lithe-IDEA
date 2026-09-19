import Foundation
import LitheApplicationKernel
import LitheLanguageIntelligenceModule
import LitheModuleAPI
@testable import Lithe
import Testing

@MainActor
struct ExtensionHostStartupTests {
    @Test(arguments: [false, true])
    func cancellingPreparationDoesNotConstructOrTakeOverHost(cancelCaller: Bool) async throws {
        let started = TestGate()
        let release = TestGate()
        let resources = ModuleResourceScope(moduleID: JavaExtensionPluginCatalog.moduleID)
        let runtime = ModuleRuntime()
        var constructed = false
        var tookOver = false
        let module = ExtensionHostModule(manifest: JavaExtensionPluginCatalog.moduleManifest,
            capabilityID: JavaExtensionPluginCatalog.capabilityID,
            makeSession: {
                constructed = true
                return ExtensionHostSession(transport: MacExtensionHostTransport())
            }, startup: { _ in
                started.open()
                guard await release.waitUntilOpen() else { throw CancellationError() }
                throw ExtensionHostFailure("notInitialized", "No runtime should start in this test")
            }, onSessionCreated: { _, _ in tookOver = true })
        let context = ModuleContext(moduleID: JavaExtensionPluginCatalog.moduleID,
            workspaceURL: URL(fileURLWithPath: "/fixture/workspace"), capabilities: runtime,
            events: runtime, resources: resources, leases: resources, contributions: runtime)
        let activation = Task { try await module.activate(context: context) }
        defer { activation.cancel(); started.open(); release.open() }
        #expect(await started.waitUntilOpen())
        #expect(resources.resourceSnapshots().contains { $0.kind == "vscode-extension-host-startup" && $0.isActive })
        if cancelCaller { activation.cancel() }
        else { await resources.stopAllResources() }
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(!constructed)
        #expect(!tookOver)
        #expect(!resources.resourceSnapshots().contains { $0.isActive })
        #expect(module.exportedCapabilities().isEmpty)
    }

    @Test func cancelledTrustPromptDoesNotPresentAnAlert() async {
        let prompt = ExtensionWorkspaceTrustPrompt()
        prompt.cancel()
        #expect(await !prompt.present(URL(fileURLWithPath: "/fixture/workspace")))
    }
}
