import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Language provider catalog source")
struct LanguageProviderCatalogSourceTests {
    @Test
    func unavailableRustCoreUsesAnExplicitDegradedCompatibilityFallback() {
        let source = RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
            isAvailable: false,
            data: nil
        ))

        let snapshot = source.load()

        #expect(snapshot.origin == .compatibilityFallback)
        #expect(snapshot.status == .degraded)
        #expect(snapshot.isDegraded)
        #expect(snapshot.schemaVersion == nil)
        #expect(snapshot.issues.count == 1)
        #expect(snapshot.issues[0].message.contains("compatibility"))
        #expect(snapshot.catalog.provider(for: URL(fileURLWithPath: "/tmp/main.go"))?.id == "go")
    }

    @Test
    func invalidRustPayloadUsesAnExplicitDegradedCompatibilityFallback() {
        let source = RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
            isAvailable: true,
            data: Data("{".utf8)
        ))

        let snapshot = source.load()

        #expect(snapshot.origin == .compatibilityFallback)
        #expect(snapshot.status == .degraded)
        #expect(snapshot.issues.count == 1)
        #expect(snapshot.issues[0].message.contains("could not be decoded"))
    }

    @Test
    func rejectedWorkspaceOverridePreservesIssuesAndBuiltinCatalog() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/catalog-workspace", isDirectory: true)
        let issuePath = workspaceURL
            .appendingPathComponent(".lithe/lsp/language-providers.json")
            .path
        let source = RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
            isAvailable: true,
            data: catalogPayload(
                origin: "builtin",
                diagnostics: """
                [{"path":"\(issuePath)","message":"expected value at line 1 column 20"}]
                """
            )
        ))

        let snapshot = source.load(workspaceURL: workspaceURL)

        #expect(snapshot.origin == .builtin)
        #expect(snapshot.status == .degraded)
        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.issues == [LanguageProviderCatalogIssue(
            path: issuePath,
            message: "expected value at line 1 column 20"
        )])
        #expect(snapshot.catalog.provider(for: workspaceURL.appendingPathComponent("main.go"))?.id == "go")
    }

    @Test
    func acceptedWorkspaceOverrideReportsItsOriginWithoutDegradation() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/catalog-workspace", isDirectory: true)
        let source = RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
            isAvailable: true,
            data: catalogPayload(origin: "workspaceOverride")
        ))

        let snapshot = source.load(workspaceURL: workspaceURL)

        #expect(snapshot.origin == .workspaceOverride(
            workspaceURL.standardizedFileURL
                .appendingPathComponent(".lithe")
                .appendingPathComponent("lsp")
                .appendingPathComponent("language-providers.json")
        ))
        #expect(snapshot.status == .loaded)
        #expect(!snapshot.isDegraded)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.schemaVersion == 2)
    }

    @Test
    func installedLanguagePackageAddsAProviderMissingFromTheRustCatalog() throws {
        let source = PluginLanguageProviderCatalogSource(
            base: RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
                isAvailable: true,
                data: catalogPayload(origin: "builtin")
            )),
            languageSupports: [LanguageSupportDeclaration(
                id: "zig",
                displayName: "Zig",
                fileExtensions: ["zig"],
                projectFileNames: ["build.zig"],
                languageServerModuleID: .languageServerExtension("zig"),
                executionModuleID: .languageExecutionExtension("zig"),
                testingModuleID: .languageExecutionExtension("zig")
            )]
        )

        let workspaceURL = URL(fileURLWithPath: "/tmp/zig-workspace", isDirectory: true)
        let snapshot = source.load(workspaceURL: workspaceURL)
        let provider = try #require(snapshot.catalog.provider(
            for: workspaceURL.appendingPathComponent("src/main.zig")
        ))

        #expect(provider.id == "zig")
        #expect(provider.displayName == "Zig")
        #expect(provider.capabilities.contains(.languageServer))
        #expect(provider.capabilities.contains(.run))
        #expect(!provider.capabilities.contains(.debugAdapter))
        #expect(provider.capabilities.contains(.testing))
    }

    @Test
    func packageDeclarationOwnsItsProcessBackedCapabilities() throws {
        let source = PluginLanguageProviderCatalogSource(
            base: RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
                isAvailable: false,
                data: nil
            )),
            languageSupports: [LanguageSupportDeclaration(
                id: "go",
                displayName: "Go",
                fileExtensions: ["go"],
                languageServerModuleID: .languageServerExtension("go"),
                executionModuleID: .languageExecutionExtension("go"),
                testingModuleID: .languageExecutionExtension("go")
            )]
        )

        let provider = try #require(source.load(workspaceURL: nil).catalog.provider(
            for: URL(fileURLWithPath: "/tmp/main.go")
        ))

        #expect(provider.capabilities.contains(.languageServer))
        #expect(provider.capabilities.contains(.run))
        #expect(!provider.capabilities.contains(.debugAdapter))
        #expect(provider.capabilities.contains(.testing))
        #expect(provider.languageServerLaunch == nil)
    }

    /// A debugger plugin names the languages it debugs. It adds the debugger
    /// to a language another owner serves, and leaves that owner's server,
    /// run, test features and display name alone.
    @Test
    func debugOnlyDeclarationAddsADebuggerWithoutTakingTheLanguageOver() throws {
        let debugOnly = LanguageSupportDeclaration(
            id: "rust",
            displayName: "Rust (debugger spelling)",
            fileExtensions: ["rs"],
            debugModuleID: .debugAdaptersExtension("dev.example.debugger")
        )
        #expect(debugOnly.isDebugOnly)
        let source = URL(fileURLWithPath: "/tmp/main.rs")

        let before = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: source))
        #expect(!before.capabilities.contains(.debugAdapter))
        let after = try #require(
            LanguageProviderCatalog.compatibilityFallback
                .applying(languageSupports: [debugOnly])
                .provider(for: source)
        )

        #expect(after.capabilities.contains(.debugAdapter))
        #expect(after.capabilities.isSuperset(of: [.run, .languageServer, .testing]))
        #expect(after.displayName == before.displayName)
        // Everything but the debugger is what the language server session sees.
        #expect(after.withoutDebugAdapter == before)
        #expect(LanguageProviderCatalog.compatibilityFallback.applying(languageSupports: [debugOnly]).debugProviders
            .map(\.id).contains("rust"))
    }

    /// The package that owns a language is applied before a debugger plugin,
    /// whichever sorts first; otherwise the owner would erase the debugger.
    @Test
    func debugOnlyDeclarationSurvivesAnOwnerThatSortsAfterIt() throws {
        let owner = LanguageSupportDeclaration(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            languageServerModuleID: .languageServerExtension("rust")
        )
        let debugOnly = LanguageSupportDeclaration(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            debugModuleID: .debugAdaptersExtension("dev.example.debugger")
        )
        let source = URL(fileURLWithPath: "/tmp/main.rs")

        for declarations in [[owner, debugOnly], [debugOnly, owner]] {
            let provider = try #require(
                LanguageProviderCatalog.compatibilityFallback
                    .applying(languageSupports: declarations)
                    .provider(for: source)
            )
            #expect(provider.capabilities.contains(.debugAdapter))
            #expect(provider.capabilities.contains(.languageServer))
        }
    }

    /// A debugger plugin must not turn the host's own run and test features
    /// for that language into "extension required".
    @Test
    func debugOnlyDeclarationNeverRequiresAnExtensionForHostFeatures() {
        let debugOnly = LanguageSupportDeclaration(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            debugModuleID: .debugAdaptersExtension("dev.example.debugger")
        )
        #expect([debugOnly].languageIDs(requiringExtensionFor: .run).isEmpty)
        #expect([debugOnly].languageIDs(requiringExtensionFor: .testing).isEmpty)
    }

    /// Live plugin declarations are read when the catalog loads, so a plugin
    /// installed or turned off while the app runs changes the next load.
    @Test
    func liveDeclarationsAreReadOnEveryLoad() throws {
        let live = LiveDeclarations()
        let source = PluginLanguageProviderCatalogSource(
            base: RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(isAvailable: false, data: nil)),
            languageSupports: [],
            liveLanguageSupports: { live.value }
        )
        let rust = URL(fileURLWithPath: "/tmp/main.rs")
        #expect(try #require(source.load().catalog.provider(for: rust)).capabilities.contains(.debugAdapter) == false)

        live.value = [LanguageSupportDeclaration(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            debugModuleID: .debugAdaptersExtension("dev.example.debugger")
        )]
        #expect(try #require(source.load().catalog.provider(for: rust)).capabilities.contains(.debugAdapter))

        live.value = []
        #expect(try #require(source.load().catalog.provider(for: rust)).capabilities.contains(.debugAdapter) == false)
    }

    @Test
    func installedPackageKeepsSharedLaunchMetadataForItsControlCenter() throws {
        let source = PluginLanguageProviderCatalogSource(
            base: RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
                isAvailable: true,
                data: Data("""
                {
                  "version": 2,
                  "origin": "builtin",
                  "providers": [{
                    "id": "php",
                    "displayName": "PHP",
                    "fileExtensions": ["php"],
                    "fileNames": [],
                    "fileNamePrefixes": [],
                    "capabilities": ["languageServer"],
                    "activationPolicy": "onDemand",
                    "languageId": "php",
                    "languageIdsByExtension": {},
                    "languageIdsByFileName": {},
                    "languageServerLaunch": {
                      "executableNames": ["intelephense"],
                      "arguments": ["--stdio"],
                      "environment": {}
                    },
                    "languageServerInstallation": {
                      "homebrewFormula": "intelephense",
                      "officialDownloadURL": "https://intelephense.com/"
                    }
                  }],
                  "diagnostics": []
                }
                """.utf8)
            )),
            languageSupports: [LanguageSupportDeclaration(
                id: "php",
                displayName: "PHP",
                fileExtensions: ["php"],
                languageServerModuleID: .languageServerExtension("php")
            )]
        )

        let provider = try #require(source.load().catalog.provider(
            for: URL(fileURLWithPath: "/tmp/index.php")
        ))

        #expect(provider.languageServerLaunch?.executableNames == ["intelephense"])
        #expect(provider.languageServerLaunch?.arguments == ["--stdio"])
        #expect(provider.languageServerInstallation == nil)
    }

    @Test
    func syntaxOnlyBundledLanguagesDoNotAdvertiseAnUnimplementedServer() throws {
        let source = PluginLanguageProviderCatalogSource(
            base: RustLanguageProviderCatalogSource(loader: CatalogPayloadLoader(
                isAvailable: false,
                data: nil
            )),
            languageSupports: BundledLanguagePluginCatalog.languageSupports
        )
        let catalog = source.load().catalog
        let markdown = try #require(catalog.provider(
            for: URL(fileURLWithPath: "/tmp/README.md")
        ))
        let yaml = try #require(catalog.provider(
            for: URL(fileURLWithPath: "/tmp/config.yaml")
        ))

        #expect(!markdown.capabilities.contains(.languageServer))
        #expect(yaml.capabilities.contains(.languageServer))
        #expect(markdown.languageServerLaunch == nil)
        #expect(yaml.languageServerLaunch == nil)
    }

    private func catalogPayload(origin: String, diagnostics: String = "[]") -> Data {
        Data("""
        {
          "version": 2,
          "origin": "\(origin)",
          "providers": [{
            "id": "go",
            "displayName": "Go",
            "fileExtensions": ["go"],
            "fileNames": [],
            "fileNamePrefixes": [],
            "capabilities": ["languageServer"],
            "activationPolicy": "onDemand",
            "languageId": "go",
            "languageIdsByExtension": {},
            "languageIdsByFileName": {}
          }],
          "diagnostics": \(diagnostics)
        }
        """.utf8)
    }
}

private struct CatalogPayloadLoader: RustLanguageProviderCatalogLoading {
    let isAvailable: Bool
    let data: Data?

    func languageProviderCatalogData(workspaceURL _: URL?) -> Data? { data }
}

/// Stands in for the live plugin registry the catalog source reads on each load.
private final class LiveDeclarations: @unchecked Sendable {
    private let lock = NSLock()
    private var declarations: [LanguageSupportDeclaration] = []

    var value: [LanguageSupportDeclaration] {
        get { lock.withLock { declarations } }
        set { lock.withLock { declarations = newValue } }
    }
}
