import Foundation
import LitheModuleAPI

struct MacPluginLanguageServerManifest: Decodable {
    let schemaVersion: Int
    let pluginID: String
    let toolID: String
    let version: String
    let archiveURL: URL
    let archiveSHA256: String
    let archiveFormat: String
    let archiveRoot: String
    let entrypoint: String
    let license: String
}

enum MacPluginLanguageServerPackageValidationError: Error, Equatable, LocalizedError {
    case missingManifest
    case invalidManifest
    case missingLauncher

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            "language-server.json is missing."
        case .invalidManifest:
            "language-server.json contains invalid metadata."
        case .missingLauncher:
            "The Intelephense launcher is missing."
        }
    }
}

enum MacPluginLanguageServerPackageValidator {
    static func validate(
        packageAt packageURL: URL,
        pluginManifest: PluginManifest,
        fileManager: FileManager = .default
    ) throws {
        guard pluginManifest.id == OfficialPluginCatalog.phpPluginID else { return }
        let manifestURL = packageURL.appendingPathComponent("language-server.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw MacPluginLanguageServerPackageValidationError.missingManifest
        }
        let languageServerManifest: MacPluginLanguageServerManifest
        do {
            languageServerManifest = try JSONDecoder().decode(
                MacPluginLanguageServerManifest.self,
                from: data
            )
        } catch {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        guard languageServerManifest.schemaVersion == 1,
              languageServerManifest.pluginID == pluginManifest.id.rawValue,
              languageServerManifest.toolID == "intelephense",
              !languageServerManifest.version.isEmpty,
              languageServerManifest.archiveURL.scheme?.lowercased() == "https",
              languageServerManifest.archiveURL.host != nil,
              languageServerManifest.archiveFormat == "tarGzip",
              isSafeRelativePath(languageServerManifest.archiveRoot),
              isSafeRelativePath(languageServerManifest.entrypoint),
              isSafeRelativePath(languageServerManifest.license),
              languageServerManifest.archiveSHA256.count == 64,
              languageServerManifest.archiveSHA256.allSatisfy({ $0.isHexDigit }),
              case .nativeBundle = pluginManifest.entrypoint.kind,
              let bundlePath = pluginManifest.entrypoint.bundlePath else {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        let launcherURL = packageURL
            .appendingPathComponent(bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Resources/LanguageServers/php/bin/intelephense")
        guard fileManager.isExecutableFile(atPath: launcherURL.path) else {
            throw MacPluginLanguageServerPackageValidationError.missingLauncher
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
