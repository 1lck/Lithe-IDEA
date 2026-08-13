import Foundation

/// The single registration surface for language capabilities.
///
/// Existing registries remain available as focused implementation details, but
/// the application composition root should create this registry once and pass
/// its derived views to Run, Debug, and Test services. LSP metadata is resolved
/// by the Rust language-server host, not by Swift language packs.
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
            return LanguagePack(
                descriptor: descriptor,
                runProvider: runProvider,
                toolchainProviders: standardToolchains.filter {
                    $0.languageProviderID == descriptor.id
                },
                debugAdapterLaunch: Self.standardDebugAdapterDefinition(for: descriptor.id),
                toolingRuntime: runtimeByID[descriptor.id],
                testProviders: testProviders
            )
        }
        return Self(packs: packs)
    }

    private static func standardDebugAdapterDefinition(for id: String) -> StdioDebugAdapterLaunch? {
        switch id {
        case "java":
            return StdioDebugAdapterLaunch(
                adapterID: "java",
                executableNames: ["java-debug-adapter", "java-debug"],
                arguments: ["--stdio"]
            )
        case "go":
            return StdioDebugAdapterLaunch(
                adapterID: "go",
                executableNames: ["dlv"],
                arguments: ["dap"]
            )
        case "python":
            return StdioDebugAdapterLaunch(
                adapterID: "python",
                executableNames: ["python3", "python"],
                arguments: ["-m", "debugpy.adapter"]
            )
        case "node":
            return StdioDebugAdapterLaunch(
                adapterID: "pwa-node",
                executableNames: ["js-debug-dap"],
                arguments: []
            )
        case "rust":
            return StdioDebugAdapterLaunch(
                adapterID: "lldb",
                executableNames: ["lldb-dap"],
                arguments: [],
                fallbacks: [
                    // Xcode exposes lldb-dap through xcrun even when the
                    // app's inherited PATH does not contain the tool.
                    .init(executableName: "xcrun", argumentPrefix: ["lldb-dap"])
                ]
            )
        default:
            return nil
        }
    }
}
