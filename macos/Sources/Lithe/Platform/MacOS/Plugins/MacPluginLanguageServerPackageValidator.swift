import Foundation
import LitheCoreContracts
import LitheModuleAPI

struct MacPluginLanguageServerManifest: Codable {
    let schemaVersion: Int
    let pluginID: String
    let languageID: String
    let toolID: String
    let version: String
    let archiveURL: URL
    let archiveSHA256: String
    let archiveFormat: String
    let archiveRoot: String
    let launcherRelativePath: String
    let arguments: [String]
    let entrypoint: String
    let license: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pluginID, languageID, toolID, version, archiveURL
        case archiveSHA256, archiveFormat, archiveRoot, launcherRelativePath
        case arguments, entrypoint, license
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        pluginID = try values.decode(String.self, forKey: .pluginID)
        languageID = try values.decode(String.self, forKey: .languageID)
        toolID = try values.decode(String.self, forKey: .toolID)
        version = try values.decode(String.self, forKey: .version)
        archiveURL = try values.decode(URL.self, forKey: .archiveURL)
        archiveSHA256 = try values.decode(String.self, forKey: .archiveSHA256)
        archiveFormat = try values.decode(String.self, forKey: .archiveFormat)
        archiveRoot = try values.decode(String.self, forKey: .archiveRoot)
        launcherRelativePath = try values.decode(String.self, forKey: .launcherRelativePath)
        arguments = try values.decode([String].self, forKey: .arguments)
        entrypoint = try values.decode(String.self, forKey: .entrypoint)
        license = try values.decode(String.self, forKey: .license)
    }
}

private struct PluginManifestValidationRequest: Encodable {
    let hostVersion: String
    let manifest: ToolingJSONValue
}

private struct PluginLanguageServerValidationRequest: Encodable {
    let pluginID: String
    let manifest: ToolingJSONValue
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
            "The plugin language-server launcher is missing."
        }
    }
}

enum MacPluginLanguageServerPackageValidator {
    static func validate(
        packageAt packageURL: URL,
        pluginManifest: PluginManifest,
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion,
        fileManager: FileManager = .default
    ) throws {
        guard pluginManifest.languageSupports?.contains(where: {
            $0.languageServerModuleID != nil
        }) == true else { return }
        let manifestURL = packageURL.appendingPathComponent("language-server.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw MacPluginLanguageServerPackageValidationError.missingManifest
        }
        let core = RustCoreBridge()
        guard core.isAvailable else {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        let languageServerManifest: MacPluginLanguageServerManifest
        do {
            // Forward the original JSON. Decoding into Swift DTOs first would
            // silently normalize or drop fields before Core sees the package.
            let decoder = JSONDecoder()
            let rawManifest = try decoder.decode(ToolingJSONValue.self, from: Data(
                contentsOf: packageURL.appendingPathComponent("plugin.json")
            ))
            let rawLanguageServer = try decoder.decode(ToolingJSONValue.self, from: data)
            let _: ToolingJSONValue = try core.executeResult(
                command: "plugin.validateManifest",
                payload: PluginManifestValidationRequest(
                    hostVersion: hostVersion.description,
                    manifest: rawManifest
                )
            ).get()
            languageServerManifest = try core.executeResult(
                command: "plugin.validateLanguageServer",
                payload: PluginLanguageServerValidationRequest(
                    pluginID: pluginManifest.id.rawValue,
                    manifest: rawLanguageServer
                )
            ).get()
        } catch {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        guard languageServerManifest.pluginID == pluginManifest.id.rawValue,
              pluginManifest.languageSupports?.contains(where: { $0.id == languageServerManifest.languageID }) == true,
              case .nativeBundle = pluginManifest.entrypoint.kind,
              let bundlePath = pluginManifest.entrypoint.bundlePath else {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        let launcherURL = packageURL
            .appendingPathComponent(bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Resources/LanguageServers", isDirectory: true)
            .appendingPathComponent(languageServerManifest.languageID, isDirectory: true)
            .appendingPathComponent(languageServerManifest.launcherRelativePath)
        guard fileManager.isExecutableFile(atPath: launcherURL.path) else {
            throw MacPluginLanguageServerPackageValidationError.missingLauncher
        }
    }

}
