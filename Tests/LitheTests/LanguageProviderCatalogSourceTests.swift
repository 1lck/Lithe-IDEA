import Foundation
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
