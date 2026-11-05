import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// Uses the published contract fixtures and production Core adapters at all three admission gates.
@Suite("Toolchain plugin admission")
@MainActor
struct ToolchainPluginAdmissionTests {
    @Test func providerIsAvailableReviewedAndLoadedWithBackendEnablement() throws {
        let manifest = try fixture("toolchains/toolchain-provider.plugin.json")
        let descriptor = try checkAdmission(manifest)
        #expect(descriptor.declaresBackend)
        #expect(descriptor.pluginManifest.modules.map(\.manifest.id) == [.backendExtension(descriptor.id.rawValue)])
        #expect(MacPluginBackendSessions.toolchainProviderIDs(ofManifest: descriptor.normalizedManifest) == ["mise"])
        let review = try PluginMarketplaceTestSupport.evaluator.installReview(
            manifest: manifest, expectedID: descriptor.id.rawValue,
            expectedVersion: descriptor.pluginManifest.version.description, approvedPrograms: nil)
        #expect(review.permissions == ["backend.launch", "toolchains.provide"])
        #expect(review.programs.map(\.path) == ["bin/mise-provider"])
    }

    /// Definitions are data the host reads each time a tool is resolved, so a
    /// plugin that only carries them applies without a restart.
    @Test func standaloneDefinitionHasEnablementAndActivatesWithoutARestart() throws {
        let descriptor = try checkAdmission(fixture("toolchains/tool-definition.plugin.json"))
        #expect(!descriptor.declaresBackend)
        #expect(descriptor.pluginManifest.modules.map(\.manifest.id) == [.toolchainsExtension(descriptor.id.rawValue)])
        #expect(descriptor.pluginManifest.modules.allSatisfy { $0.manifest.defaultState == .disabled })
        #expect(descriptor.canActivateWithoutRestart)
        let registry = try ValidatedPluginCatalog(manifests: [descriptor.pluginManifest],
                                                  hostVersion: BuiltInPluginCatalog.hostVersion)
        #expect(registry.manifests.count == 1)
        let installed = InstalledPluginPackage(descriptor: descriptor,
            installation: PluginInstallationRecord(pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version, origin: .localDevelopment),
            packageURL: DeclarativePluginTestSupport.repositoryRoot)
        let factories = MacServiceContainer.declarativePluginFactories([installed],
            executionHost: MacLanguageExecutionHost(processRegistry: ManagedProcessRegistry()),
            planner: DeclarativePluginTestSupport.operations)
        #expect(factories.map(\.manifest.id) == descriptor.pluginManifest.modules.map(\.manifest.id))
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(name)"))
    }

    private func checkAdmission(_ manifest: Data) throws -> DeclarativePluginDescriptor {
        let object = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let id = try #require(object["id"] as? String)
        var entry = PluginMarketplaceTestSupport.entry(id: id, repository: "https://github.com/example/toolchain",
            version: "1.0.0", archiveURL: "https://github.com/example/toolchain/releases/download/v1.0.0/toolchain.zip",
            sha256: String(repeating: "a", count: 64))
        var versions = try #require(entry["versions"] as? [[String: Any]])
        versions[0]["pluginAPIVersion"] = object["pluginAPIVersion"]
        versions[0]["requires"] = object["requires"]
        entry["versions"] = versions
        let index = try PluginMarketplaceTestSupport.evaluator.validateIndex(
            PluginMarketplaceTestSupport.indexData([entry]), sourceKind: .official, platform: "darwin-arm64")
        let listed = try #require(index.plugins.first)
        #expect(listed.availability.download?.version == "1.0.0")
        _ = try PluginMarketplaceTestSupport.evaluator.installReview(manifest: manifest,
            expectedID: id, expectedVersion: "1.0.0", approvedPrograms: nil)
        return try DeclarativePluginTestSupport.operations.validate(manifest: manifest)
    }
}
