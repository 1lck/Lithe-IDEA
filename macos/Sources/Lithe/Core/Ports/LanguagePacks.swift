import Foundation
import LitheExecutionModule

/// A complete, platform-neutral description of one language ecosystem.
///
/// The pack is deliberately only a composition value. It does not start
/// processes or inspect the file system; the platform composition root injects
/// the runtime and toolchain adapters when it builds the registry.
@MainActor
struct LanguagePack {
    let descriptor: LanguageProviderDescriptor
    let runProvider: (any LanguageRunProvider)?
    let toolchainProviders: [any RunToolchainProvider]
    let toolingRuntime: (any LanguageProviderRuntime)?
    let testProviders: [any LanguageTestProvider]

    init(
        descriptor: LanguageProviderDescriptor,
        runProvider: (any LanguageRunProvider)? = nil,
        toolchainProviders: [any RunToolchainProvider] = [],
        toolingRuntime: (any LanguageProviderRuntime)? = nil,
        testProviders: [any LanguageTestProvider] = []
    ) {
        self.descriptor = descriptor
        self.runProvider = runProvider
        self.toolchainProviders = toolchainProviders
        self.toolingRuntime = toolingRuntime
        self.testProviders = testProviders
    }

    func withRuntime(_ runtime: (any LanguageProviderRuntime)?) -> Self {
        Self(
            descriptor: descriptor,
            runProvider: runProvider,
            toolchainProviders: toolchainProviders,
            toolingRuntime: runtime,
            testProviders: testProviders
        )
    }
}
