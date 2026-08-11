import Foundation
import LitheRustCore

protocol LanguageProviderCatalogSource: Sendable {
    func catalog(workspaceURL: URL?) -> LanguageProviderCatalog
}

struct RustLanguageProviderCatalogSource: LanguageProviderCatalogSource {
    private struct CatalogPayload: Decodable {
        let providers: [ProviderPayload]
    }

    private struct LanguageServerLaunchPayload: Decodable {
        let executableNames: [String]
        let arguments: [String]
        let environment: [String: String]
        let initializationOptions: ToolingJSONValue?

        func makeDescriptor() -> LanguageServerLaunchDescriptor {
            LanguageServerLaunchDescriptor(
                executableNames: executableNames,
                arguments: arguments,
                environment: environment,
                initializationOptions: initializationOptions
            )
        }
    }

    private struct LanguageServerInstallationPayload: Decodable {
        let homebrewFormula: String?
        let officialDownloadURL: String?

        func makeDescriptor() -> LanguageServerInstallationDescriptor {
            LanguageServerInstallationDescriptor(
                homebrewFormula: homebrewFormula,
                officialDownloadURL: officialDownloadURL.flatMap(URL.init(string:))
            )
        }
    }

    private struct ProviderPayload: Decodable {
        let id: String
        let displayName: String
        let fileExtensions: [String]
        let fileNames: [String]
        let fileNamePrefixes: [String]
        let capabilities: [String]
        let activationPolicy: ToolingActivationPolicy
        let languageId: String?
        let languageIdsByExtension: [String: String]
        let languageIdsByFileName: [String: String]
        let languageServerLaunch: LanguageServerLaunchPayload?
        let languageServerInstallation: LanguageServerInstallationPayload?

        func makeDescriptor() -> LanguageProviderDescriptor {
            LanguageProviderDescriptor(
                id: id,
                displayName: displayName,
                fileExtensions: Set(fileExtensions),
                fileNames: Set(fileNames),
                fileNamePrefixes: Set(fileNamePrefixes),
                capabilities: LanguageToolingCapability.names(capabilities),
                activationPolicy: activationPolicy,
                languageIdentifier: languageId,
                languageIdentifiersByExtension: languageIdsByExtension,
                languageIdentifiersByFileName: languageIdsByFileName,
                languageServerLaunch: languageServerLaunch?.makeDescriptor(),
                languageServerInstallation: languageServerInstallation?.makeDescriptor()
            )
        }
    }

    let core: RustCoreBridge

    init(core: RustCoreBridge = RustCoreBridge()) {
        self.core = core
    }

    func catalog(workspaceURL: URL? = nil) -> LanguageProviderCatalog {
        guard let payload = loadPayload(workspaceURL: workspaceURL) else {
            return .compatibilityFallback
        }
        return LanguageProviderCatalog(
            descriptors: payload.providers.map { $0.makeDescriptor() }
        )
    }

    private func loadPayload(workspaceURL: URL?) -> CatalogPayload? {
        guard core.isAvailable else { return nil }
        let responsePointer: UnsafeMutablePointer<CChar>?
        if let workspaceURL {
            responsePointer = workspaceURL.standardizedFileURL.path.withCString {
                lithe_bridge_lsp_provider_catalog_json($0)
            }
        } else {
            responsePointer = lithe_bridge_lsp_provider_catalog_json(nil)
        }
        guard let responsePointer else { return nil }
        defer { lithe_bridge_free_string(responsePointer) }
        let response = String(cString: responsePointer)
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CatalogPayload.self, from: data)
    }
}

extension LanguageProviderCatalog {
    static var standard: Self {
        RustLanguageProviderCatalogSource().catalog()
    }
}
