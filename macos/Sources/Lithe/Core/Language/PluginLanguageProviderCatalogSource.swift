import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Overlays installed language-package metadata onto the shared Rust catalog.
/// Recognition stays inert: reading a manifest never loads plugin code or
/// starts a toolchain process.
struct PluginLanguageProviderCatalogSource: LanguageProviderCatalogSource {
    private let base: any LanguageProviderCatalogSource
    private let languageSupports: [LanguageSupportDeclaration]

    init(
        base: any LanguageProviderCatalogSource,
        languageSupports: [LanguageSupportDeclaration]
    ) {
        self.base = base
        self.languageSupports = languageSupports.sorted { $0.id < $1.id }
    }

    func load(workspaceURL: URL? = nil) -> LanguageProviderCatalogSnapshot {
        let snapshot = base.load(workspaceURL: workspaceURL)
        return LanguageProviderCatalogSnapshot(
            catalog: snapshot.catalog.applying(languageSupports: languageSupports),
            schemaVersion: snapshot.schemaVersion,
            origin: snapshot.origin,
            issues: snapshot.issues
        )
    }
}

extension LanguageProviderCatalog {
    func applying(
        languageSupports: [LanguageSupportDeclaration]
    ) -> LanguageProviderCatalog {
        var merged = descriptors
        var indicesByID = Dictionary(
            uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) }
        )

        for support in languageSupports.sorted(by: { $0.id < $1.id }) {
            let existingIndex = indicesByID[support.id]
            let existing = existingIndex.map { merged[$0] }
            var capabilities = existing?.capabilities ?? []

            // Process-backed capabilities declared by a language package are
            // authoritative. This prevents a shared fallback catalog from
            // silently running tools after the package module is disabled.
            capabilities.subtract([.run, .languageServer, .debugAdapter, .testing])
            if support.languageServerModuleID != nil { capabilities.insert(.languageServer) }
            if support.executionModuleID != nil { capabilities.insert(.run) }
            if support.testingModuleID != nil { capabilities.insert(.testing) }
            if support.debugModuleID != nil { capabilities.insert(.debugAdapter) }

            let descriptor = LanguageProviderDescriptor(
                id: support.id,
                displayName: support.displayName,
                fileExtensions: Set(support.fileExtensions).union(existing?.fileExtensions ?? []),
                fileNames: Set(support.fileNames).union(existing?.fileNames ?? []),
                fileNamePrefixes: existing?.fileNamePrefixes ?? [],
                capabilities: capabilities,
                activationPolicy: existing?.activationPolicy ?? .onDemand,
                languageIdentifier: existing?.languageIdentifier ?? support.id,
                languageIdentifiersByExtension: existing?.languageIdentifiersByExtension ?? [:],
                languageIdentifiersByFileName: existing?.languageIdentifiersByFileName ?? [:],
                languageServerLaunch: nil,
                languageServerInstallation: existing?.languageServerInstallation
            )

            if let existingIndex {
                merged[existingIndex] = descriptor
            } else {
                indicesByID[support.id] = merged.endIndex
                merged.append(descriptor)
            }
        }
        return LanguageProviderCatalog(descriptors: merged)
    }
}
