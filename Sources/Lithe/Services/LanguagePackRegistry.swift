import Foundation

/// The single registration surface for language capabilities.
///
/// Existing registries remain available as focused implementation details, but
/// the application composition root should create this registry once and pass
/// its derived views to Run, LSP/DAP, and Test services. Adding a language then
/// means adding one pack instead of editing every service initializer.
@MainActor
final class LanguagePackRegistry {
    let packs: [LanguagePack]
    let catalog: LanguageProviderCatalog
    let runProviders: LanguageRunProviderRegistry
    let toolchainRegistry: RunToolchainRegistry
    let toolingRuntimes: [any LanguageProviderRuntime]
    let testProviders: LanguageTestProviderRegistry

    init(packs: [LanguagePack]) {
        let ids = packs.map { $0.descriptor.id }
        precondition(
            Set(ids).count == ids.count,
            "Language pack identifiers must be unique"
        )

        self.packs = packs
        catalog = LanguageProviderCatalog(descriptors: packs.map(\.descriptor))
        runProviders = LanguageRunProviderRegistry(
            providers: packs.compactMap(\.runProvider)
        )
        toolchainRegistry = RunToolchainRegistry(
            providers: packs.flatMap(\.toolchainProviders)
        )
        toolingRuntimes = packs.compactMap(\.toolingRuntime)
        testProviders = LanguageTestProviderRegistry(
            providers: packs.flatMap(\.testProviders)
        )
    }

    func pack(for fileURL: URL) -> LanguagePack? {
        guard let descriptor = catalog.provider(for: fileURL) else { return nil }
        return pack(id: descriptor.id)
    }

    func pack(id: String) -> LanguagePack? {
        packs.first { $0.descriptor.id == id }
    }

    /// Builds the in-tree language packs. Runtime objects are injected by the
    /// platform composition root; constructing this value itself is inert.
    static func standard(
        catalog: LanguageProviderCatalog = .standard,
        runtimes: [any LanguageProviderRuntime] = []
    ) -> Self {
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.descriptor.id, $0)
        })
        let standardToolchains = RunToolchainRegistry.standardProviders()

        let packs = catalog.descriptors.map { descriptor in
            let runProvider: (any LanguageRunProvider)? = descriptor.id == "java"
                ? nil
                : descriptor.capabilities.contains(.run)
                    ? StandardLanguageRunProvider(descriptor: descriptor)
                    : nil
            let testProviders: [any LanguageTestProvider] = descriptor.capabilities.contains(.testing)
                ? [StandardLanguageTestProvider(descriptor: descriptor)]
                : []
            let tooling = Self.standardToolingDefinition(for: descriptor.id)

            return LanguagePack(
                descriptor: descriptor,
                runProvider: runProvider,
                toolchainProviders: standardToolchains.filter {
                    $0.languageProviderID == descriptor.id
                },
                languageServerLaunch: tooling.languageServer,
                debugAdapterLaunch: tooling.debugAdapter,
                toolingRuntime: runtimeByID[descriptor.id],
                testProviders: testProviders
            )
        }
        return Self(packs: packs)
    }

    private struct StandardToolingDefinition {
        let languageServer: StdioLanguageServerLaunch?
        let debugAdapter: StdioDebugAdapterLaunch?
    }

    /// The standard catalog is intentionally assembled as complete packs.
    /// Runtime implementations consume these definitions but never duplicate
    /// language-name-to-executable maps of their own.
    private static func standardToolingDefinition(for id: String) -> StandardToolingDefinition {
        switch id {
        case "java":
            return StandardToolingDefinition(
                languageServer: nil,
                debugAdapter: StdioDebugAdapterLaunch(
                    adapterID: "java",
                    executableNames: ["java-debug-adapter", "java-debug", "jdtls-debug"],
                    arguments: ["--stdio"]
                )
            )
        case "go":
            return StandardToolingDefinition(
                languageServer: StdioLanguageServerLaunch(
                    executableNames: ["gopls"],
                    arguments: []
                ),
                debugAdapter: StdioDebugAdapterLaunch(
                    adapterID: "go",
                    executableNames: ["dlv"],
                    arguments: ["dap"]
                )
            )
        case "python":
            return StandardToolingDefinition(
                languageServer: StdioLanguageServerLaunch(
                    executableNames: ["basedpyright-langserver", "pyright-langserver"],
                    arguments: ["--stdio"]
                ),
                debugAdapter: StdioDebugAdapterLaunch(
                    adapterID: "python",
                    executableNames: ["python3", "python"],
                    arguments: ["-m", "debugpy.adapter"]
                )
            )
        case "node":
            return StandardToolingDefinition(
                languageServer: StdioLanguageServerLaunch(
                    executableNames: ["typescript-language-server"],
                    arguments: ["--stdio"]
                ),
                debugAdapter: StdioDebugAdapterLaunch(
                    adapterID: "pwa-node",
                    executableNames: ["js-debug-dap"],
                    arguments: []
                )
            )
        case "rust":
            return StandardToolingDefinition(
                languageServer: StdioLanguageServerLaunch(
                    executableNames: ["rust-analyzer"],
                    arguments: []
                ),
                debugAdapter: StdioDebugAdapterLaunch(
                    adapterID: "lldb",
                    executableNames: ["lldb-dap"],
                    arguments: [],
                    fallbacks: [
                        // Xcode exposes lldb-dap through xcrun even when the
                        // app's inherited PATH does not contain the tool.
                        .init(executableName: "xcrun", argumentPrefix: ["lldb-dap"])
                    ]
                )
            )
        default:
            return StandardToolingDefinition(languageServer: nil, debugAdapter: nil)
        }
    }
}
