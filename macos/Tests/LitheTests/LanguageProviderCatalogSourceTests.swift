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

    /// Java Support ships only a language server. Running, testing, and
    /// debugging Java stay host features, which the package declares on its
    /// `jdt` integration; without that declaration the catalog would drop
    /// them and the toolbar would report Java as unsupported.
    @Test
    func officialJavaPackageKeepsTheHostFeaturesItsIntegrationDeclares() throws {
        let supports = try #require(
            try DeclarativePluginTestSupport.officialDescriptor("JavaSupport")
                .pluginManifest.languageSupports
        )
        #expect(supports.map(\.hostCapabilities) == [[.debug, .run, .testing]])
        #expect(supports.languageIDs(requiringExtensionFor: .run).isEmpty)
        #expect(supports.languageIDs(requiringExtensionFor: .testing).isEmpty)

        let provider = try #require(
            LanguageProviderCatalog.compatibilityFallback
                .applying(languageSupports: supports)
                .provider(for: URL(fileURLWithPath: "/tmp/Main.java"))
        )
        #expect(provider.capabilities.contains(.languageServer))
        #expect(provider.capabilities.contains(.run))
        #expect(provider.capabilities.contains(.debugAdapter))
        #expect(provider.capabilities.contains(.testing))
    }

    /// The declaration is the only way back to a host feature: a package
    /// that owns a language and declares nothing gets none of them, even
    /// though the shared catalog lists them.
    @Test
    func packageWithoutHostCapabilitiesGetsNoHostFeature() throws {
        let undeclared = LanguageSupportDeclaration(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"],
            languageServerModuleID: .languageServerExtension("java")
        )
        let debugOnly = LanguageSupportDeclaration(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"],
            languageServerModuleID: .languageServerExtension("java"),
            hostCapabilities: [.debug]
        )
        let capabilities: (LanguageSupportDeclaration) throws -> LanguageToolingCapability = {
            try #require(
                LanguageProviderCatalog.compatibilityFallback
                    .applying(languageSupports: [$0])
                    .provider(for: URL(fileURLWithPath: "/tmp/Main.java"))
            ).capabilities
        }

        let none = try capabilities(undeclared)
        #expect(none.contains(.languageServer))
        #expect(none.isDisjoint(with: [.run, .debugAdapter, .testing]))
        let debug = try capabilities(debugOnly)
        #expect(debug.contains(.debugAdapter))
        #expect(debug.isDisjoint(with: [.run, .testing]))
        #expect([undeclared].languageIDs(requiringExtensionFor: .testing) == ["java"])
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
