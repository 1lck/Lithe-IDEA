import Foundation
import LitheRustCore

enum LanguageProviderCatalogOrigin: Equatable, Sendable {
    case builtin
    /// The associated URL is the accepted workspace configuration file.
    case workspaceOverride(URL)
    case compatibilityFallback
}

enum LanguageProviderCatalogStatus: Equatable, Sendable {
    case loaded
    case degraded
}

struct LanguageProviderCatalogIssue: Equatable, Sendable {
    let path: String
    let message: String
}

struct LanguageProviderCatalogSnapshot: Sendable {
    let catalog: LanguageProviderCatalog
    let schemaVersion: Int?
    let origin: LanguageProviderCatalogOrigin
    let status: LanguageProviderCatalogStatus
    let issues: [LanguageProviderCatalogIssue]

    var isDegraded: Bool { status == .degraded }

    init(
        catalog: LanguageProviderCatalog,
        schemaVersion: Int?,
        origin: LanguageProviderCatalogOrigin,
        issues: [LanguageProviderCatalogIssue]
    ) {
        self.catalog = catalog
        self.schemaVersion = schemaVersion
        self.origin = origin
        self.issues = issues
        if case .compatibilityFallback = origin {
            status = .degraded
        } else {
            status = issues.isEmpty ? .loaded : .degraded
        }
    }
}

protocol LanguageProviderCatalogSource: Sendable {
    func load(workspaceURL: URL?) -> LanguageProviderCatalogSnapshot
}

extension LanguageProviderCatalogSource {
    func catalog(workspaceURL: URL?) -> LanguageProviderCatalog {
        load(workspaceURL: workspaceURL).catalog
    }
}

protocol RustLanguageProviderCatalogLoading: Sendable {
    var isAvailable: Bool { get }
    func languageProviderCatalogData(workspaceURL: URL?) -> Data?
}

extension RustCoreBridge: RustLanguageProviderCatalogLoading {
    func languageProviderCatalogData(workspaceURL: URL?) -> Data? {
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
        guard let response = String(validatingUTF8: responsePointer) else { return nil }
        return response.data(using: .utf8)
    }
}

struct RustLanguageProviderCatalogSource: LanguageProviderCatalogSource {
    private enum CatalogOriginPayload: String, Decodable {
        case builtin
        case workspaceOverride
    }

    private struct CatalogPayload: Decodable {
        let version: Int
        let origin: CatalogOriginPayload
        let providers: [ProviderPayload]
        let diagnostics: [CatalogDiagnosticPayload]?
    }

    private struct CatalogDiagnosticPayload: Decodable {
        let path: String
        let message: String

        func makeIssue() -> LanguageProviderCatalogIssue {
            LanguageProviderCatalogIssue(path: path, message: message)
        }
    }

    private struct LanguageServerLaunchPayload: Decodable {
        let executableNames: [String]
        let arguments: [String]
        let validationArguments: [String]?
        let environment: [String: String]
        let initializationOptions: ToolingJSONValue?

        func makeDescriptor() -> LanguageServerLaunchDescriptor {
            LanguageServerLaunchDescriptor(
                executableNames: executableNames,
                arguments: arguments,
                validationArguments: validationArguments ?? [],
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

    private let loader: any RustLanguageProviderCatalogLoading

    init(core: RustCoreBridge = RustCoreBridge()) {
        loader = core
    }

    init(loader: any RustLanguageProviderCatalogLoading) {
        self.loader = loader
    }

    func load(workspaceURL: URL? = nil) -> LanguageProviderCatalogSnapshot {
        guard loader.isAvailable else {
            return compatibilityFallback(
                message: "The Rust core is unavailable. Lithe is using its compatibility language-provider catalog."
            )
        }
        guard let data = loader.languageProviderCatalogData(workspaceURL: workspaceURL) else {
            return compatibilityFallback(
                message: "The Rust core did not return a valid UTF-8 language-provider catalog."
            )
        }

        let payload: CatalogPayload
        do {
            payload = try JSONDecoder().decode(CatalogPayload.self, from: data)
        } catch {
            return compatibilityFallback(
                message: "The Rust language-provider catalog could not be decoded: \(error.localizedDescription)"
            )
        }

        let issues = (payload.diagnostics ?? []).map { $0.makeIssue() }
        return LanguageProviderCatalogSnapshot(
            catalog: LanguageProviderCatalog(
                descriptors: payload.providers.map { $0.makeDescriptor() }
            ),
            schemaVersion: payload.version,
            origin: resolvedOrigin(
                payloadOrigin: payload.origin,
                workspaceURL: workspaceURL
            ),
            issues: issues
        )
    }

    private func resolvedOrigin(
        payloadOrigin: CatalogOriginPayload,
        workspaceURL: URL?
    ) -> LanguageProviderCatalogOrigin {
        switch payloadOrigin {
        case .workspaceOverride:
            if let workspaceURL {
                return .workspaceOverride(
                    workspaceURL.standardizedFileURL
                        .appendingPathComponent(".lithe")
                        .appendingPathComponent("lsp")
                        .appendingPathComponent("language-providers.json")
                )
            }
            return .builtin
        case .builtin:
            return .builtin
        }
    }

    private func compatibilityFallback(message: String) -> LanguageProviderCatalogSnapshot {
        LanguageProviderCatalogSnapshot(
            catalog: .compatibilityFallback,
            schemaVersion: nil,
            origin: .compatibilityFallback,
            issues: [LanguageProviderCatalogIssue(
                path: "rust:lsp-provider-catalog",
                message: message
            )]
        )
    }
}

extension LanguageProviderCatalog {
    static var standard: Self {
        RustLanguageProviderCatalogSource().load().catalog
    }
}
