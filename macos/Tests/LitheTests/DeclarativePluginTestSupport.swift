import Foundation
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

/// Loads official declarative plugins from the repository through the same
/// Rust Core validation the application uses. Go and PHP Support moved to
/// community plugins; their last official manifests stay as fixtures because
/// installed copies keep the official trust policy.
enum DeclarativePluginTestSupport {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static var operations: RustDeclarativePluginOperations {
        RustDeclarativePluginOperations(core: RustCoreBridge())
    }

    static let retiredOfficialPackages: Set<String> = ["GoSupport", "PhpSupport"]

    static func officialPackageURL(_ directoryName: String) -> URL {
        let parent = retiredOfficialPackages.contains(directoryName)
            ? "macos/Tests/LitheTests/Fixtures/RetiredOfficialPlugins"
            : "Plugins/mac/Official"
        return repositoryRoot
            .appendingPathComponent(parent, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func officialManifestData(_ directoryName: String) throws -> Data {
        try Data(contentsOf: officialPackageURL(directoryName).appendingPathComponent("plugin.json"))
    }

    static func officialDescriptor(_ directoryName: String) throws -> DeclarativePluginDescriptor {
        try operations.validate(manifest: officialManifestData(directoryName))
    }

    /// A minimal valid declarative manifest with one language server.
    static func manifestObject(
        id: String = "dev.example.plugin",
        version: PluginVersion,
        signatureRequirement: PluginSignatureRequirement = .sameTeamAsHost,
        languageID: String = "fixture",
        packagedLauncher: String? = nil
    ) -> [String: Any] {
        let launch: [String: Any] = packagedLauncher.map { ["kind": "packaged", "path": $0] }
            ?? ["kind": "systemCommand", "commands": ["\(languageID)-language-server"]]
        return [
            "schemaVersion": 2,
            "id": id,
            "displayName": "Example Plugin",
            "version": version.description,
            "pluginAPIVersion": 1,
            "vendor": [
                "id": "dev.example",
                "displayName": "Example",
                "signatureRequirement": signatureRequirement.rawValue
            ],
            "permissions": ["languageServer.launch"],
            "activationEvents": ["onLanguage:\(languageID)"],
            "languages": [[
                "id": languageID,
                "displayName": "Fixture",
                "fileExtensions": [languageID]
            ]],
            "languageServers": [[
                "languageID": languageID,
                "launch": launch
            ]]
        ]
    }

    /// Writes a declarative package directory. A packaged launcher path also
    /// creates that executable inside the package.
    @discardableResult
    static func writePackage(
        at packageURL: URL,
        manifest: [String: Any]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: packageURL.appendingPathComponent("plugin.json"), options: .atomic)
        let servers = manifest["languageServers"] as? [[String: Any]] ?? []
        for server in servers {
            guard let launch = server["launch"] as? [String: Any],
                  launch["kind"] as? String == "packaged",
                  let path = launch["path"] as? String else { continue }
            let launcher = packageURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: launcher.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: launcher, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        }
        return packageURL
    }

    /// Writes an official plugin's real declaration, optionally edited, with
    /// placeholder packaged executables.
    @discardableResult
    static func writeOfficialPackage(
        _ directoryName: String,
        at packageURL: URL,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> URL {
        var manifest = try JSONSerialization.jsonObject(
            with: officialManifestData(directoryName)
        ) as? [String: Any] ?? [:]
        edit(&manifest)
        return try writePackage(at: packageURL, manifest: manifest)
    }

    static func descriptor(_ manifest: [String: Any]) throws -> DeclarativePluginDescriptor {
        try operations.validate(manifest: JSONSerialization.data(withJSONObject: manifest))
    }

    /// Host-owned module factories for one official plugin, as the
    /// composition root registers them.
    @MainActor
    static func officialFactories(
        _ directoryName: String,
        executionHost: any LanguageExecutionHostProviding
    ) throws -> [ModuleFactory] {
        let descriptor = try officialDescriptor(directoryName)
        let installed = InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id,
                activeVersion: descriptor.pluginManifest.version,
                origin: .bundled
            ),
            packageURL: officialPackageURL(directoryName)
        )
        return MacServiceContainer.declarativePluginFactories(
            [installed],
            executionHost: executionHost,
            planner: operations
        )
    }
}

/// Plugin settings that live only in memory, for tests that do not exercise
/// persistence.
final class InMemoryPluginSettings: PluginSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: [String: ToolingJSONValue]]

    init(_ records: [String: [String: ToolingJSONValue]] = [:]) {
        self.records = records
    }

    func values(forPlugin pluginID: String) -> [String: ToolingJSONValue] {
        lock.lock(); defer { lock.unlock() }
        return records[pluginID] ?? [:]
    }

    func setValue(_ value: ToolingJSONValue?, forSetting settingID: String, plugin pluginID: String) {
        lock.lock(); defer { lock.unlock() }
        records[pluginID, default: [:]][settingID] = value
    }
}
