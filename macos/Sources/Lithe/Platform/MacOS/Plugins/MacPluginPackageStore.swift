import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Security

protocol PluginPackageSignatureVerifying {
    func verify(packageAt packageURL: URL, manifest: PluginManifest) throws
}

enum PluginPackageStoreError: Error, Equatable, LocalizedError {
    case invalidPackageDirectory
    case unsafeIdentifier(String)
    case manifestDoesNotMatchInstallation
    case versionAlreadyInstalled(PluginVersion)
    case missingInstallation(PluginID)
    case rollbackUnavailable(PluginID)
    case requiredPluginCannotBeUninstalled(PluginID)
    case unsupportedEntrypoint(PluginID)
    case invalidBundlePath(PluginID)
    case unsignedCode(URL)
    case invalidCodeSignature(URL)
    case signingTeamMismatch
    case invalidInstalledPlugin(PluginID?, String)

    var errorDescription: String? {
        switch self {
        case .invalidPackageDirectory: "The plugin package directory is invalid."
        case .unsafeIdentifier(let value): "Plugin package identifier is unsafe: \(value)."
        case .manifestDoesNotMatchInstallation: "Plugin manifest does not match its installation record."
        case .versionAlreadyInstalled(let version): "Plugin version \(version) is already installed."
        case .missingInstallation(let id): "Plugin \(id) is not installed."
        case .rollbackUnavailable(let id): "Plugin \(id) has no previous version to restore."
        case .requiredPluginCannotBeUninstalled(let id): "Required plugin \(id) cannot be uninstalled."
        case .unsupportedEntrypoint(let id): "Plugin \(id) is not an installable native bundle."
        case .invalidBundlePath(let id): "Plugin \(id) has an invalid bundle path."
        case .unsignedCode(let url): "Plugin code is not signed: \(url.lastPathComponent)."
        case .invalidCodeSignature(let url): "Plugin signature is invalid: \(url.lastPathComponent)."
        case .signingTeamMismatch: "Plugin and host application signing teams do not match."
        case .invalidInstalledPlugin(let id, let message):
            if let id {
                "Installed plugin \(id) is invalid: \(message)"
            } else {
                "An installed plugin is invalid: \(message)"
            }
        }
    }
}

struct InstalledPluginPackage: Equatable {
    let manifest: PluginManifest
    let installation: PluginInstallationRecord
    let packageURL: URL
}

struct PluginPackageScanIssue: Equatable {
    let pluginID: PluginID?
    let message: String
}

struct PluginPackageScanResult: Equatable {
    let packages: [InstalledPluginPackage]
    let issues: [PluginPackageScanIssue]
}

final class MacPluginPackageStore {
    private let rootURL: URL
    private let bundledRootURL: URL?
    private let hostVersion: PluginVersion
    private let verifier: any PluginPackageSignatureVerifying
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        rootURL: URL,
        bundledRootURL: URL? = nil,
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion,
        verifier: any PluginPackageSignatureVerifying = MacOfficialPluginSignatureVerifier(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.bundledRootURL = bundledRootURL?.standardizedFileURL
        self.hostVersion = hostVersion
        self.verifier = verifier
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    convenience init(fileStorage: any FileStorage) {
        self.init(
            rootURL: fileStorage.applicationSupportDirectory()
                .appendingPathComponent("Lithe/Plugins", isDirectory: true),
            bundledRootURL: Bundle.main.resourceURL?
                .appendingPathComponent("OfficialPlugins", isDirectory: true)
        )
    }

    /// Completes operations that were deferred because the previous process
    /// could still have the plugin bundle mapped in memory.
    func prepareForLaunch() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let pluginDirectories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for pluginDirectory in pluginDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let record = try? installationRecord(at: pluginDirectory) else { continue }
            switch record.status {
            case .installed:
                continue
            case .updateStaged:
                try write(PluginInstallationRecord(
                    pluginID: record.pluginID,
                    activeVersion: record.activeVersion,
                    previousVersion: record.previousVersion,
                    origin: record.origin,
                    status: .installed
                ), to: pluginDirectory.appendingPathComponent("installation.json"))
            case .uninstallPending:
                try fileManager.removeItem(at: pluginDirectory)
            }
        }
    }

    func installedPlugins() throws -> [InstalledPluginPackage] {
        let result = try scanInstalledPlugins()
        if let issue = result.issues.first {
            throw PluginPackageStoreError.invalidInstalledPlugin(issue.pluginID, issue.message)
        }
        return result.packages
    }

    /// Reads and verifies every package independently so one damaged optional
    /// plugin cannot prevent the host from starting or managing the others.
    func scanInstalledPlugins() throws -> PluginPackageScanResult {
        var installed: [InstalledPluginPackage] = []
        var issues: [PluginPackageScanIssue] = []
        if let bundledRootURL, fileManager.fileExists(atPath: bundledRootURL.path) {
            let bundled = scanBundledPlugins(at: bundledRootURL)
            installed = bundled.packages
            issues = bundled.issues
        }
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return PluginPackageScanResult(packages: installed, issues: issues)
        }
        let pluginDirectories = try pluginDirectories(at: rootURL)

        for pluginDirectory in pluginDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var issuePluginID: PluginID?
            do {
                let record = try decode(
                    PluginInstallationRecord.self,
                    at: pluginDirectory.appendingPathComponent("installation.json")
                )
                issuePluginID = record.pluginID
                try validatePathComponent(record.pluginID.rawValue)
                guard pluginDirectory.lastPathComponent == record.pluginID.rawValue else {
                    throw PluginPackageStoreError.manifestDoesNotMatchInstallation
                }
                let packageURL = versionDirectory(
                    pluginDirectory: pluginDirectory,
                    version: record.activeVersion
                )
                let manifest = try loadManifest(at: packageURL)
                guard manifest.id == record.pluginID,
                      manifest.version == record.activeVersion else {
                    throw PluginPackageStoreError.manifestDoesNotMatchInstallation
                }
                _ = try ValidatedPluginCatalog(manifests: [manifest], hostVersion: hostVersion)
                try verifier.verify(packageAt: packageURL, manifest: manifest)
                let candidate = InstalledPluginPackage(
                    manifest: manifest,
                    installation: record,
                    packageURL: packageURL
                )
                let packagesWithoutBundledVersion = installed.filter {
                    $0.manifest.id != candidate.manifest.id
                }
                _ = try ValidatedPluginCatalog(
                    manifests: packagesWithoutBundledVersion.map(\.manifest) + [manifest],
                    hostVersion: hostVersion
                )
                installed = packagesWithoutBundledVersion + [candidate]
            } catch {
                issues.append(PluginPackageScanIssue(
                    pluginID: issuePluginID,
                    message: error.localizedDescription
                ))
            }
        }
        return PluginPackageScanResult(
            packages: installed.sorted { $0.manifest.id < $1.manifest.id },
            issues: issues
        )
    }

    private func scanBundledPlugins(at bundledRootURL: URL) -> PluginPackageScanResult {
        var installed: [InstalledPluginPackage] = []
        var issues: [PluginPackageScanIssue] = []
        let directories: [URL]
        do {
            directories = try pluginDirectories(at: bundledRootURL)
        } catch {
            return PluginPackageScanResult(
                packages: [],
                issues: [PluginPackageScanIssue(pluginID: nil, message: error.localizedDescription)]
            )
        }

        for packageURL in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var issuePluginID: PluginID?
            do {
                let manifest = try loadManifest(at: packageURL)
                issuePluginID = manifest.id
                try validatePathComponent(manifest.id.rawValue)
                guard packageURL.lastPathComponent == manifest.id.rawValue else {
                    throw PluginPackageStoreError.manifestDoesNotMatchInstallation
                }
                _ = try ValidatedPluginCatalog(
                    manifests: installed.map(\.manifest) + [manifest],
                    hostVersion: hostVersion
                )
                try verifier.verify(packageAt: packageURL, manifest: manifest)
                installed.append(InstalledPluginPackage(
                    manifest: manifest,
                    installation: PluginInstallationRecord(
                        pluginID: manifest.id,
                        activeVersion: manifest.version,
                        origin: .bundled
                    ),
                    packageURL: packageURL
                ))
            } catch {
                issues.append(PluginPackageScanIssue(
                    pluginID: issuePluginID,
                    message: error.localizedDescription
                ))
            }
        }
        return PluginPackageScanResult(packages: installed, issues: issues)
    }

    private func pluginDirectories(at directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    @discardableResult
    func installPackage(
        from sourceURL: URL,
        deferActivationUntilRestart: Bool = false
    ) throws -> InstalledPluginPackage {
        let sourceManifest = try loadManifest(at: sourceURL)
        _ = try ValidatedPluginCatalog(manifests: [sourceManifest], hostVersion: hostVersion)
        try validatePathComponent(sourceManifest.id.rawValue)

        let stagingRoot = rootURL.appendingPathComponent(".staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagedURL = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        var shouldRemoveStaging = true
        defer { if shouldRemoveStaging { try? fileManager.removeItem(at: stagedURL) } }

        let manifest = try loadManifest(at: stagedURL)
        guard manifest == sourceManifest else {
            throw PluginPackageStoreError.manifestDoesNotMatchInstallation
        }
        try verifier.verify(packageAt: stagedURL, manifest: manifest)

        let pluginDirectory = rootURL.appendingPathComponent(manifest.id.rawValue, isDirectory: true)
        let versionsDirectory = pluginDirectory.appendingPathComponent("versions", isDirectory: true)
        try fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let destination = versionDirectory(
            pluginDirectory: pluginDirectory,
            version: manifest.version
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PluginPackageStoreError.versionAlreadyInstalled(manifest.version)
        }

        let existingRecord = try? installationRecord(at: pluginDirectory)
        try fileManager.moveItem(at: stagedURL, to: destination)
        shouldRemoveStaging = false
        do {
            let record = PluginInstallationRecord(
                pluginID: manifest.id,
                activeVersion: manifest.version,
                previousVersion: existingRecord?.activeVersion,
                origin: .marketplace,
                status: deferActivationUntilRestart ? .updateStaged : .installed
            )
            try write(record, to: pluginDirectory.appendingPathComponent("installation.json"))
            return InstalledPluginPackage(
                manifest: manifest,
                installation: record,
                packageURL: destination
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    @discardableResult
    func rollback(
        _ pluginID: PluginID,
        deferActivationUntilRestart: Bool = false
    ) throws -> InstalledPluginPackage {
        try validatePathComponent(pluginID.rawValue)
        let pluginDirectory = rootURL.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        let record = try installationRecord(at: pluginDirectory)
        guard let previousVersion = record.previousVersion else {
            throw PluginPackageStoreError.rollbackUnavailable(pluginID)
        }
        let previousPackageURL = versionDirectory(
            pluginDirectory: pluginDirectory,
            version: previousVersion
        )
        let manifest = try loadManifest(at: previousPackageURL)
        guard manifest.id == pluginID, manifest.version == previousVersion else {
            throw PluginPackageStoreError.manifestDoesNotMatchInstallation
        }
        let restored = PluginInstallationRecord(
            pluginID: pluginID,
            activeVersion: previousVersion,
            previousVersion: record.activeVersion,
            origin: record.origin,
            status: deferActivationUntilRestart ? .updateStaged : .installed
        )
        try write(restored, to: pluginDirectory.appendingPathComponent("installation.json"))
        return InstalledPluginPackage(
            manifest: manifest,
            installation: restored,
            packageURL: previousPackageURL
        )
    }

    func uninstall(_ pluginID: PluginID) throws {
        try validatePathComponent(pluginID.rawValue)
        let pluginDirectory = rootURL.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        guard fileManager.fileExists(atPath: pluginDirectory.path) else {
            throw PluginPackageStoreError.missingInstallation(pluginID)
        }
        let record = try installationRecord(at: pluginDirectory)
        let manifest = try loadManifest(at: versionDirectory(
            pluginDirectory: pluginDirectory,
            version: record.activeVersion
        ))
        guard !manifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginPackageStoreError.requiredPluginCannotBeUninstalled(pluginID)
        }
        try fileManager.removeItem(at: pluginDirectory)
    }

    func stageUninstall(_ pluginID: PluginID) throws {
        try validatePathComponent(pluginID.rawValue)
        let pluginDirectory = rootURL.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        let record = try installationRecord(at: pluginDirectory)
        let manifest = try loadManifest(at: versionDirectory(
            pluginDirectory: pluginDirectory,
            version: record.activeVersion
        ))
        guard !manifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginPackageStoreError.requiredPluginCannotBeUninstalled(pluginID)
        }
        try write(PluginInstallationRecord(
            pluginID: record.pluginID,
            activeVersion: record.activeVersion,
            previousVersion: record.previousVersion,
            origin: record.origin,
            status: .uninstallPending
        ), to: pluginDirectory.appendingPathComponent("installation.json"))
    }

    /// Recovery path for an unreadable active package. The installation
    /// record is deliberately sufficient to schedule removal without opening
    /// the plugin manifest or loading any plugin code.
    func stageInvalidPackageUninstall(_ pluginID: PluginID) throws {
        try validatePathComponent(pluginID.rawValue)
        let pluginDirectory = rootURL.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        let record = try installationRecord(at: pluginDirectory)
        try write(PluginInstallationRecord(
            pluginID: record.pluginID,
            activeVersion: record.activeVersion,
            previousVersion: record.previousVersion,
            origin: record.origin,
            status: .uninstallPending
        ), to: pluginDirectory.appendingPathComponent("installation.json"))
    }

    private func loadManifest(at packageURL: URL) throws -> PluginManifest {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw PluginPackageStoreError.invalidPackageDirectory
        }
        return try decode(
            PluginManifest.self,
            at: packageURL.appendingPathComponent("plugin.json")
        )
    }

    private func installationRecord(at pluginDirectory: URL) throws -> PluginInstallationRecord {
        let url = pluginDirectory.appendingPathComponent("installation.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw PluginPackageStoreError.missingInstallation(
                PluginID(pluginDirectory.lastPathComponent)
            )
        }
        return try decode(PluginInstallationRecord.self, at: url)
    }

    private func versionDirectory(pluginDirectory: URL, version: PluginVersion) -> URL {
        pluginDirectory
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version.description, isDirectory: true)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        try decoder.decode(type, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func validatePathComponent(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PluginPackageStoreError.unsafeIdentifier(value)
        }
    }
}

struct MacOfficialPluginSignatureVerifier: PluginPackageSignatureVerifying {
    func verify(packageAt packageURL: URL, manifest: PluginManifest) throws {
        guard manifest.entrypoint.kind == .nativeBundle else {
            throw PluginPackageStoreError.unsupportedEntrypoint(manifest.id)
        }
        guard let relativePath = manifest.entrypoint.bundlePath,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw PluginPackageStoreError.invalidBundlePath(manifest.id)
        }
        let pluginBundleURL = packageURL.appendingPathComponent(relativePath).standardizedFileURL
        guard pluginBundleURL.path.hasPrefix(packageURL.standardizedFileURL.path + "/") else {
            throw PluginPackageStoreError.invalidBundlePath(manifest.id)
        }
        let pluginCode = try staticCode(at: pluginBundleURL)
        let hostCode = try staticCode(at: Bundle.main.bundleURL)
        let validationFlags = SecCSFlags(
            rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        )
        guard SecStaticCodeCheckValidity(pluginCode, validationFlags, nil) == errSecSuccess else {
            throw PluginPackageStoreError.invalidCodeSignature(pluginBundleURL)
        }
        let pluginTeam = try teamIdentifier(for: pluginCode)
        let hostTeam = try teamIdentifier(for: hostCode)
        if let pluginTeam, let hostTeam {
            guard pluginTeam == hostTeam else {
                throw PluginPackageStoreError.signingTeamMismatch
            }
            return
        }
        let hostBundlePath = Bundle.main.bundleURL.standardizedFileURL.path + "/"
        guard pluginTeam == nil,
              hostTeam == nil,
              pluginBundleURL.path.hasPrefix(hostBundlePath) else {
            throw PluginPackageStoreError.signingTeamMismatch
        }
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw PluginPackageStoreError.unsignedCode(url)
        }
        return code
    }

    private func teamIdentifier(for code: SecStaticCode) throws -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let values = information as? [CFString: Any] else {
            throw PluginPackageStoreError.signingTeamMismatch
        }
        guard let teamID = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamID.isEmpty else { return nil }
        return teamID
    }
}
