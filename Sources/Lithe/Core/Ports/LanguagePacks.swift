import Foundation

/// Process launch metadata shared by the platform runtimes.  These values are
/// intentionally just names and arguments; resolving an executable and
/// starting a process remains a platform responsibility.
struct StdioLanguageServerLaunch: Sendable, Equatable {
    let executableNames: [String]
    let arguments: [String]
}

struct StdioDebugAdapterLaunch: Sendable, Equatable {
    struct Fallback: Sendable, Equatable {
        let executableName: String
        let argumentPrefix: [String]
    }

    let adapterID: String
    let executableNames: [String]
    let arguments: [String]
    var fallbacks: [Fallback]

    init(
        adapterID: String,
        executableNames: [String],
        arguments: [String],
        fallbacks: [Fallback] = []
    ) {
        self.adapterID = adapterID
        self.executableNames = executableNames
        self.arguments = arguments
        self.fallbacks = fallbacks
    }
}

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
    let languageServerLaunch: StdioLanguageServerLaunch?
    let debugAdapterLaunch: StdioDebugAdapterLaunch?
    let toolingRuntime: (any LanguageProviderRuntime)?
    let testProviders: [any LanguageTestProvider]

    init(
        descriptor: LanguageProviderDescriptor,
        runProvider: (any LanguageRunProvider)? = nil,
        toolchainProviders: [any RunToolchainProvider] = [],
        languageServerLaunch: StdioLanguageServerLaunch? = nil,
        debugAdapterLaunch: StdioDebugAdapterLaunch? = nil,
        toolingRuntime: (any LanguageProviderRuntime)? = nil,
        testProviders: [any LanguageTestProvider] = []
    ) {
        self.descriptor = descriptor
        self.runProvider = runProvider
        self.toolchainProviders = toolchainProviders
        self.languageServerLaunch = languageServerLaunch
        self.debugAdapterLaunch = debugAdapterLaunch
        self.toolingRuntime = toolingRuntime
        self.testProviders = testProviders
    }

    func withRuntime(_ runtime: (any LanguageProviderRuntime)?) -> Self {
        Self(
            descriptor: descriptor,
            runProvider: runProvider,
            toolchainProviders: toolchainProviders,
            languageServerLaunch: languageServerLaunch,
            debugAdapterLaunch: debugAdapterLaunch,
            toolingRuntime: runtime,
            testProviders: testProviders
        )
    }
}
