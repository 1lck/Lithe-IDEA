import Foundation
import LitheCoreContracts
import LitheModuleAPI

struct MacPluginLanguageServerManifest: Codable {
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
        let core = RustCoreBridge()
        guard core.isAvailable else {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        let languageServerManifest: MacPluginLanguageServerManifest
        let declaredLaunches = try launches(packageAt: packageURL, for: pluginManifest)
        do {
            // Forward the original JSON. Decoding into Swift DTOs first would
            // silently normalize or drop fields before Core sees the package.
            let decoder = JSONDecoder()
            let rawManifest = try decoder.decode(ToolingJSONValue.self, from: Data(
                contentsOf: packageURL.appendingPathComponent("plugin.json")
            ))
            let _: ToolingJSONValue = try core.executeResult(
                command: "plugin.validateManifest",
                payload: PluginManifestValidationRequest(
                    hostVersion: hostVersion.description,
                    manifest: rawManifest
                )
            ).get()
            let packagedLaunches = declaredLaunches.values.filter { $0.source == "package" }
            guard !packagedLaunches.isEmpty else { return }
            let manifestURL = packageURL.appendingPathComponent("language-server.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw MacPluginLanguageServerPackageValidationError.missingManifest
            }
            let data = try Data(contentsOf: manifestURL)
            let rawLanguageServer = try decoder.decode(ToolingJSONValue.self, from: data)
            languageServerManifest = try core.executeResult(
                command: "plugin.validateLanguageServer",
                payload: PluginLanguageServerValidationRequest(
                    pluginID: pluginManifest.id.rawValue,
                    manifest: rawLanguageServer
                )
            ).get()
        } catch let error as MacPluginLanguageServerPackageValidationError {
            throw error
        } catch {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        guard languageServerManifest.pluginID == pluginManifest.id.rawValue,
              case .nativeBundle = pluginManifest.entrypoint.kind,
              let bundlePath = pluginManifest.entrypoint.bundlePath else {
            throw MacPluginLanguageServerPackageValidationError.invalidManifest
        }
        let packageRoot = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let bundleRoot = packageRoot.appendingPathComponent(bundlePath).resolvingSymlinksInPath().standardizedFileURL
        for launch in declaredLaunches.values where launch.source == "package" {
            guard launch.executable == languageServerManifest.toolID,
                  let relativePath = launch.launcherRelativePath else {
                throw MacPluginLanguageServerPackageValidationError.invalidManifest
            }
            let launcherURL = bundleRoot.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
            guard bundleRoot.path.hasPrefix(packageRoot.path + "/"),
                  launcherURL.path.hasPrefix(bundleRoot.path + "/"),
                  fileManager.isExecutableFile(atPath: launcherURL.path) else {
                throw MacPluginLanguageServerPackageValidationError.missingLauncher
            }
        }
    }

    static func launches(packageAt packageURL: URL, for manifest: PluginManifest) throws -> [String: PluginLanguageServerLaunch] {
        guard (manifest.languageSupports ?? []).contains(where: { $0.languageServerModuleID != nil }) else { return [:] }
        let declared = try PluginLanguageServerDeclarations.decode(from: Data(
            contentsOf: packageURL.appendingPathComponent("plugin.json")))
        if !declared.isEmpty { return declared }
        // Published PHP v1 packages already contain the same pinned server;
        // legacy Go packages still use their original system-tool discovery.
        return manifest.id == OfficialPluginCatalog.phpPluginID ? OfficialPluginManifests.phpLanguageServers : [:]
    }
}
