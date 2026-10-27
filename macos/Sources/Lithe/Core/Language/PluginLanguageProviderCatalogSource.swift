import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Overlays installed language-package metadata onto the shared Rust catalog.
/// Recognition stays inert: reading a manifest never loads plugin code or
/// starts a toolchain process.
struct PluginLanguageProviderCatalogSource: LanguageProviderCatalogSource {
    private let base: any LanguageProviderCatalogSource
    private let languageSupports: [LanguageSupportDeclaration]
    /// Declarations of plugins that take effect without a restart. Read on
    /// every load, so the catalog follows installation and enablement.
    private let liveLanguageSupports: @Sendable () -> [LanguageSupportDeclaration]

    init(
        base: any LanguageProviderCatalogSource,
        languageSupports: [LanguageSupportDeclaration],
        liveLanguageSupports: @escaping @Sendable () -> [LanguageSupportDeclaration] = { [] }
    ) {
        self.base = base
        self.languageSupports = languageSupports.sorted { $0.id < $1.id }
        self.liveLanguageSupports = liveLanguageSupports
    }

    func load(workspaceURL: URL? = nil) -> LanguageProviderCatalogSnapshot {
        let snapshot = base.load(workspaceURL: workspaceURL)
        return LanguageProviderCatalogSnapshot(
            catalog: snapshot.catalog.applying(languageSupports: languageSupports + liveLanguageSupports()),
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

        // Debug-only declarations go last: they add to what the owning package
        // declared, and an owner applied after them would erase their debugger.
        let ordered = languageSupports.sorted {
            ($0.isDebugOnly ? 1 : 0, $0.id) < ($1.isDebugOnly ? 1 : 0, $1.id)
        }
        for support in ordered {
            let existingIndex = indicesByID[support.id]
            let existing = existingIndex.map { merged[$0] }
            var capabilities = existing?.capabilities ?? []

            // Process-backed capabilities declared by a language package are
            // authoritative. This prevents a shared fallback catalog from
            // silently running tools after the package module is disabled.
            // A debug-only declaration adds a debugger to a language another
            // package or the catalog already provides; it must not take that
            // language's server, run, or test features away.
            let isDebugOnly = support.isDebugOnly && existing != nil
            if !isDebugOnly {
                capabilities.subtract([.run, .languageServer, .debugAdapter, .testing])
            }
            if support.languageServerModuleID != nil { capabilities.insert(.languageServer) }
            if support.executionModuleID != nil { capabilities.insert(.run) }
            if support.testingModuleID != nil { capabilities.insert(.testing) }
            if support.debugModuleID != nil { capabilities.insert(.debugAdapter) }
            // A package may hand a feature back to the host's own
            // implementation through its host integration. That is still the
            // package's declaration, not a fallback: without it the feature
            // stays off.
            if support.hostCapabilities.contains(.run) { capabilities.insert(.run) }
            if support.hostCapabilities.contains(.testing) { capabilities.insert(.testing) }
            if support.hostCapabilities.contains(.debug) { capabilities.insert(.debugAdapter) }

            let descriptor = LanguageProviderDescriptor(
                id: support.id,
                // A debugger's own spelling of the language ("C/C++") must not
                // rename the language the owning package or catalog declared.
                displayName: isDebugOnly ? existing?.displayName ?? support.displayName : support.displayName,
                fileExtensions: Set(support.fileExtensions).union(existing?.fileExtensions ?? []),
                fileNames: Set(support.fileNames).union(existing?.fileNames ?? []),
                fileNamePrefixes: existing?.fileNamePrefixes ?? [],
                capabilities: capabilities,
                activationPolicy: existing?.activationPolicy ?? .onDemand,
                // A debug-only declaration leaves the language exactly as its
                // owner described it, so adding a debugger never changes what
                // the language server session is built from.
                languageIdentifier: isDebugOnly ? existing?.languageIdentifier : existing?.languageIdentifier ?? support.id,
                languageIdentifiersByExtension: existing?.languageIdentifiersByExtension ?? [:],
                languageIdentifiersByFileName: existing?.languageIdentifiersByFileName ?? [:],
                // The extension owns whether the process may run, while the
                // shared catalog still owns the descriptive launch metadata
                // used by setup and diagnostics. Keeping this metadata lets
                // an installed PHP extension appear in the LSP control
                // center without restoring a fallback process path. Package
                // owned servers must not expose the generic Homebrew/official
                // installer, because Plugin Management owns their lifecycle.
                languageServerLaunch: existing?.languageServerLaunch,
                languageServerInstallation: support.languageServerModuleID == nil
                    ? existing?.languageServerInstallation
                    : nil
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
