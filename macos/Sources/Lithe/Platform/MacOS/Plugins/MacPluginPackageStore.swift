import CryptoKit
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning

protocol PluginPackageSignatureVerifying: Sendable {
    func verify(
        packageAt packageURL: URL,
        manifest: PluginManifest,
        origin: PluginInstallationOrigin
    ) throws
}

enum PluginPackageStoreError: Error, Equatable, LocalizedError {
    case invalidPackageDirectory
    case unsafeIdentifier(String)
    case manifestDoesNotMatchInstallation
    case versionAlreadyInstalled(PluginVersion)
    case missingInstallation(PluginID)
    case rollbackUnavailable(PluginID)
    case requiredPluginCannotBeUninstalled(PluginID)
    case missingPackageSignature
    case invalidPackageSignature(String)
    case officialSignatureRequirementMismatch(PluginID)
    case retiredPlugin(PluginID)
    case invalidInstalledPlugin(PluginID?, String)
    case developmentPackageNotAllowed(PluginID)
    /// `plugin.legacyNative.updateRequired`: a schema-1 Swift bundle package.
    case legacyNativePackage(PluginID, PluginVersion)
    case declarationRejected(PluginID?, DeclarativePluginRejection)
    /// `plugin.launch.missing`: the packaged language server is unusable.
    case languageServerLaunchMissing(PluginID, String)
    /// A file a build system's provider launch points at is missing, outside
    /// the package, reached through a symbolic link, or not executable.
    case buildProviderLaunchMissing(PluginID, buildSystemID: String, path: String)
    /// A `sameTeamAsHost` package outside the host's sealed installation.
    case hostSealRequired(PluginID)
    /// An unsigned package outside a confirmed community installation, or
    /// an official-namespace package without a Lithe signature.
    case unsignedPackageNotAllowed(PluginID)
    /// A community package whose files differ from what the user approved.
    case communityContentChanged(PluginID)

    var errorDescription: String? {
        switch self {
        case .invalidPackageDirectory: "The plugin package directory is invalid."
        case .unsafeIdentifier(let value): "Plugin package identifier is unsafe: \(value)."
        case .manifestDoesNotMatchInstallation: "Plugin manifest does not match its installation record."
        case .versionAlreadyInstalled(let version): "Plugin version \(version) is already installed."
        case .missingInstallation(let id): "Plugin \(id) is not installed."
        case .rollbackUnavailable(let id): "Plugin \(id) has no previous version to restore."
        case .requiredPluginCannotBeUninstalled(let id): "Required plugin \(id) cannot be uninstalled."
        case .missingPackageSignature: "The official plugin package signature is missing."
        case .invalidPackageSignature(let detail): "The official plugin package signature is invalid: \(detail)"
        case .officialSignatureRequirementMismatch(let id):
            "Official plugin \(id) declares a signature policy that does not match the host trust policy."
        case .retiredPlugin(let id): "Plugin \(id) has been removed from Lithe. Uninstall the old package."
        case .developmentPackageNotAllowed(let id):
            "Plugin \(id) is an unsigned development package. Only development builds of Lithe can load it."
        case .legacyNativePackage(let id, let version):
            "Plugin \(id) \(version) is a retired native package and is no longer loaded. Reinstall it from Plugin Management to update."
        case .declarationRejected(_, let rejection):
            rejection.message
        case .languageServerLaunchMissing(let id, let path):
            "Plugin \(id) is missing its language server or it is not executable: \(path)."
        case .buildProviderLaunchMissing(let id, let buildSystemID, let path):
            "Plugin \(id) is missing the \(buildSystemID) build provider's file or it is not usable: \(path)."
        case .hostSealRequired(let id):
            "Plugin \(id) can only be trusted when it ships inside Lithe."
        case .unsignedPackageNotAllowed(let id):
            "Plugin \(id) has no Lithe signature. Community plugins require confirmation before installation."
        case .communityContentChanged(let id):
            "Community plugin \(id) differs from its approved contents. Select the package again or reinstall it from its plugin repository."
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
    let descriptor: DeclarativePluginDescriptor
    let installation: PluginInstallationRecord
    let packageURL: URL

    var manifest: PluginManifest { descriptor.pluginManifest }
}

struct PluginPackageScanIssue: Equatable {
    let pluginID: PluginID?
    let message: String
}

struct PluginPackageScanResult: Equatable {
    let packages: [InstalledPluginPackage]
    let issues: [PluginPackageScanIssue]
}

// Note: 声明式插件包的校验与信任边界见 .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md
/// Installs and verifies declarative plugin packages. A package is accepted
/// only after Rust Core validated its `plugin.json`, the host trust policy and
/// signature checks passed, and every packaged executable it declares exists.
/// Installed packages are never modified at runtime.
final class MacPluginPackageStore {
    private static let retiredPluginIDs: Set<PluginID> = [
        PluginID("dev.lithe.plugin.linux-do-support")
    ]
    private let rootURL: URL
    private let bundledRootURL: URL?
    /// Writable language-server state owned by installed plugins; removed
    /// together with the plugin so an uninstall leaves nothing behind.
    private let stateDirectories: MacPluginStateDirectories?
    private let hostVersion: PluginVersion
    private let validator: any DeclarativePluginManifestValidating
    /// Expands build provider launches so installation can check the files
    /// they point at. A package that declares a provider is refused without it.
    private let launchPlanner: (any DeclarativeLanguageServerLaunchPlanning)?
    private let verifier: any PluginPackageSignatureVerifying
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        rootURL: URL,
        bundledRootURL: URL? = nil,
        stateDirectories: MacPluginStateDirectories? = nil,
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion,
        validator: any DeclarativePluginManifestValidating,
        launchPlanner: (any DeclarativeLanguageServerLaunchPlanning)? = nil,
        verifier: any PluginPackageSignatureVerifying = MacOfficialPluginSignatureVerifier(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.bundledRootURL = bundledRootURL?.standardizedFileURL
        self.stateDirectories = stateDirectories
        self.hostVersion = hostVersion
        self.validator = validator
        self.launchPlanner = launchPlanner ?? validator as? any DeclarativeLanguageServerLaunchPlanning
        self.verifier = verifier
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    convenience init(fileStorage: any FileStorage, validator: any DeclarativePluginManifestValidating) {
        self.init(
            rootURL: fileStorage.applicationSupportDirectory()
                .appendingPathComponent("Lithe/Plugins", isDirectory: true),
            bundledRootURL: Bundle.main.resourceURL?
                .appendingPathComponent("OfficialPlugins", isDirectory: true),
            stateDirectories: MacPluginStateDirectories(fileStorage: fileStorage),
            validator: validator
        )
    }

    /// Completes installation-record transitions deferred until the next
    /// launch so module registration always reflects one consistent version.
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
            case .installed, .removed:
                continue
            case .updateStaged:
                try write(
                    record.with(status: .installed),
                    to: pluginDirectory.appendingPathComponent("installation.json")
                )
            case .uninstallPending:
                try fileManager.removeItem(at: pluginDirectory)
                removeState(of: record.pluginID)
            }
        }
        // The server of a bundled plugin removed last session has stopped by
        // now, so its state can go without pulling files from under it.
        for pluginID in removedBundledPluginIDs() {
            removeState(of: pluginID)
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
                guard !Self.retiredPluginIDs.contains(record.pluginID) else {
                    throw PluginPackageStoreError.retiredPlugin(record.pluginID)
                }
                try validatePathComponent(record.pluginID.rawValue)
                guard pluginDirectory.lastPathComponent == record.pluginID.rawValue else {
                    throw PluginPackageStoreError.manifestDoesNotMatchInstallation
                }
                let packageURL = versionDirectory(
                    pluginDirectory: pluginDirectory,
                    version: record.activeVersion
                )
                let descriptor = try loadPackage(at: packageURL)
                guard descriptor.id == record.pluginID,
                      descriptor.pluginManifest.version == record.activeVersion else {
                    throw PluginPackageStoreError.manifestDoesNotMatchInstallation
                }
                try validatePackage(
                    descriptor,
                    at: packageURL,
                    origin: record.origin,
                    marketplace: record.marketplace,
                    disk: record.disk
                )
                let candidate = InstalledPluginPackage(
                    descriptor: descriptor,
                    installation: record,
                    packageURL: packageURL
                )
                // A user-installed version of a bundled plugin replaces it.
                let packagesWithoutBundledVersion = installed.filter {
                    $0.manifest.id != candidate.manifest.id
                }
                _ = try ValidatedPluginCatalog(
                    manifests: packagesWithoutBundledVersion.map(\.manifest) + [candidate.manifest],
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
                // A package inside the application stands in for a built-in
                // feature, so its modules are on unless the user turns them off.
                let descriptor = try DeclarativePluginDescriptor(
                    normalizedManifest: try loadPackage(at: packageURL).normalizedManifest,
                    enabledByDefault: true
                )
                issuePluginID = descriptor.id
                guard !Self.retiredPluginIDs.contains(descriptor.id) else {
                    throw PluginPackageStoreError.retiredPlugin(descriptor.id)
                }
                try validatePathComponent(descriptor.id.rawValue)
                guard packageURL.lastPathComponent == descriptor.id.rawValue else {
                    throw PluginPackageStoreError.manifestDoesNotMatchInstallation
                }
                _ = try ValidatedPluginCatalog(
                    manifests: installed.map(\.manifest) + [descriptor.pluginManifest],
                    hostVersion: hostVersion
                )
                try validatePackage(descriptor, at: packageURL, origin: .bundled)
                installed.append(InstalledPluginPackage(
                    descriptor: descriptor,
                    installation: PluginInstallationRecord(
                        pluginID: descriptor.id,
                        activeVersion: descriptor.pluginManifest.version,
                        origin: .bundled
                    ).with(status: removedBundledPluginIDs().contains(descriptor.id) ? .removed : .installed),
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

    /// A preparation worker owns its decoder and never reads or writes installed
    /// records. Immutable validation policy is shared with the installation store.
    func makePreparationStoreFactory() -> @Sendable () -> MacPluginPackageStore {
        let rootURL = rootURL
        let hostVersion = hostVersion
        let validator = validator
        let verifier = verifier
        return {
            MacPluginPackageStore(
                rootURL: rootURL,
                hostVersion: hostVersion,
                validator: validator,
                verifier: verifier,
                fileManager: FileManager()
            )
        }
    }

    /// Reads and validates a package's declaration without installing it.
    func inspectPackage(at packageURL: URL) throws -> DeclarativePluginDescriptor {
        try loadPackage(at: packageURL)
    }

    /// Runs every check an installation would run, without installing, so
    /// the marketplace can refuse a package before asking the user about it.
    func verifyCandidatePackage(
        at packageURL: URL,
        origin: PluginInstallationOrigin,
        marketplace: PluginMarketplaceProvenance?,
        disk: PluginDiskProvenance? = nil
    ) throws -> DeclarativePluginDescriptor {
        let descriptor = try loadPackage(at: packageURL)
        guard !Self.retiredPluginIDs.contains(descriptor.id) else {
            throw PluginPackageStoreError.retiredPlugin(descriptor.id)
        }
        try validatePathComponent(descriptor.id.rawValue)
        try validatePackage(descriptor, at: packageURL, origin: origin, marketplace: marketplace, disk: disk)
        return descriptor
    }

    @discardableResult
    func installPackage(
        from sourceURL: URL,
        deferActivationUntilRestart: Bool = false,
        replaceExisting: Bool = false,
        origin: PluginInstallationOrigin = .marketplace,
        marketplace: PluginMarketplaceProvenance? = nil,
        disk: PluginDiskProvenance? = nil,
        beforeReplacingPackage: (PluginID) -> Void = { _ in }
    ) throws -> InstalledPluginPackage {
        let sourceDescriptor = try loadPackage(at: sourceURL)
        guard !Self.retiredPluginIDs.contains(sourceDescriptor.id) else {
            throw PluginPackageStoreError.retiredPlugin(sourceDescriptor.id)
        }
        try validateOfficialTrustPolicy(sourceDescriptor.pluginManifest)
        _ = try ValidatedPluginCatalog(manifests: [sourceDescriptor.pluginManifest], hostVersion: hostVersion)
        try validatePathComponent(sourceDescriptor.id.rawValue)

        let stagingRoot = rootURL.appendingPathComponent(".staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagedURL = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        var shouldRemoveStaging = true
        defer { if shouldRemoveStaging { try? fileManager.removeItem(at: stagedURL) } }

        // Revalidate the copy: the source directory could change after the
        // first read, and only the staged bytes are installed.
        let descriptor = try loadPackage(at: stagedURL)
        guard descriptor == sourceDescriptor else {
            throw PluginPackageStoreError.manifestDoesNotMatchInstallation
        }
        do {
            try validatePackage(descriptor, at: stagedURL, origin: origin, marketplace: marketplace, disk: disk)
        } catch let error as PluginPackageStoreError {
            switch error {
            case .languageServerLaunchMissing, .buildProviderLaunchMissing:
                throw PluginPackageStoreError.invalidInstalledPlugin(descriptor.id, error.localizedDescription)
            default:
                throw error
            }
        }

        let manifest = descriptor.pluginManifest
        let pluginDirectory = rootURL.appendingPathComponent(manifest.id.rawValue, isDirectory: true)
        let versionsDirectory = pluginDirectory.appendingPathComponent("versions", isDirectory: true)
        try fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let destination = versionDirectory(
            pluginDirectory: pluginDirectory,
            version: manifest.version
        )
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        guard !destinationExists || replaceExisting else {
            throw PluginPackageStoreError.versionAlreadyInstalled(manifest.version)
        }

        let existingRecord = try? installationRecord(at: pluginDirectory)
        let backupURL = destinationExists
            ? stagingRoot.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
            : nil
        // Validation failures leave live pages alone. Once mutation begins,
        // close every page before any installed bytes can be moved or replaced.
        beforeReplacingPackage(manifest.id)
        if let backupURL {
            try fileManager.moveItem(at: destination, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: stagedURL, to: destination)
            shouldRemoveStaging = false
        } catch {
            if let backupURL {
                try? fileManager.moveItem(at: backupURL, to: destination)
            }
            throw error
        }
        do {
            let replacesActiveVersion = existingRecord?.activeVersion == manifest.version
            let record = PluginInstallationRecord(
                pluginID: manifest.id,
                activeVersion: manifest.version,
                previousVersion: replacesActiveVersion
                    ? existingRecord?.previousVersion
                    : existingRecord?.activeVersion,
                origin: origin,
                previousOrigin: replacesActiveVersion
                    ? existingRecord?.previousOrigin
                    : existingRecord?.origin,
                status: deferActivationUntilRestart ? .updateStaged : .installed,
                marketplace: marketplace,
                previousMarketplace: replacesActiveVersion
                    ? existingRecord?.previousMarketplace
                    : existingRecord?.marketplace,
                disk: disk,
                previousDisk: replacesActiveVersion
                    ? existingRecord?.previousDisk
                    : existingRecord?.disk
            )
            try write(record, to: pluginDirectory.appendingPathComponent("installation.json"))
            if let backupURL {
                try? fileManager.removeItem(at: backupURL)
            }
            return InstalledPluginPackage(
                descriptor: descriptor,
                installation: record,
                packageURL: destination
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            if let backupURL {
                try? fileManager.moveItem(at: backupURL, to: destination)
            }
            throw error
        }
    }

    /// Restores the previous version after validating it like a fresh
    /// install. A retired native package is refused, so rollback can never
    /// return a user to a version this host will not load.
    @discardableResult
    func rollback(
        _ pluginID: PluginID,
        deferActivationUntilRestart: Bool = false,
        beforeReplacingPackage: (PluginID) -> Void = { _ in }
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
        let descriptor = try loadPackage(at: previousPackageURL)
        guard descriptor.id == pluginID, descriptor.pluginManifest.version == previousVersion else {
            throw PluginPackageStoreError.manifestDoesNotMatchInstallation
        }
        let previousOrigin = record.previousOrigin ?? record.origin
        try validatePackage(
            descriptor,
            at: previousPackageURL,
            origin: previousOrigin,
            marketplace: record.previousMarketplace,
            disk: record.previousDisk
        )
        let restored = PluginInstallationRecord(
            pluginID: pluginID,
            activeVersion: previousVersion,
            previousVersion: record.activeVersion,
            origin: previousOrigin,
            previousOrigin: record.origin,
            status: deferActivationUntilRestart ? .updateStaged : .installed,
            marketplace: record.previousMarketplace,
            previousMarketplace: record.marketplace,
            disk: record.previousDisk,
            previousDisk: record.disk
        )
        beforeReplacingPackage(pluginID)
        try write(restored, to: pluginDirectory.appendingPathComponent("installation.json"))
        return InstalledPluginPackage(
            descriptor: descriptor,
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
        let descriptor = try loadPackage(at: versionDirectory(
            pluginDirectory: pluginDirectory,
            version: record.activeVersion
        ))
        guard !descriptor.pluginManifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginPackageStoreError.requiredPluginCannotBeUninstalled(pluginID)
        }
        try fileManager.removeItem(at: pluginDirectory)
        removeState(of: pluginID)
    }

    /// Removes or restores a plugin that ships inside the application. The
    /// app bundle is read-only at runtime, so removal is recorded in the
    /// user's plugin directory instead of deleting the package: the host
    /// stops registering the plugin at the next launch. Its language-server
    /// state is deleted then too (`prepareForLaunch`), because the server
    /// keeps running, and writing there, until the application restarts. A
    /// removal restored before that loses nothing.
    func setBundledPluginRemoved(_ pluginID: PluginID, removed: Bool) throws {
        try validatePathComponent(pluginID.rawValue)
        var removedIDs = removedBundledPluginIDs()
        if removed {
            removedIDs.insert(pluginID)
        } else {
            removedIDs.remove(pluginID)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setAsideUnreadableRemovalRecord()
        try encoder.encode(removedIDs.map(\.rawValue).sorted())
            .write(to: removedBundledPluginsURL, options: .atomic)
    }

    /// Hidden so the scan of installed plugin directories never sees it.
    private var removedBundledPluginsURL: URL {
        rootURL.appendingPathComponent(".removed-bundled-plugins.json")
    }

    /// Where an unreadable removal record is kept for inspection.
    private var unreadableRemovalRecordURL: URL {
        rootURL.appendingPathComponent(".removed-bundled-plugins.json.unreadable")
    }

    /// An unreadable record cannot be trusted, so the plugins read as not
    /// removed and the application stays usable; the user's next removal then
    /// writes a fresh record (`setAsideUnreadableRemovalRecord`).
    private func removedBundledPluginIDs() -> Set<PluginID> {
        guard let data = try? Data(contentsOf: removedBundledPluginsURL),
              let ids = try? decoder.decode([String].self, from: data) else { return [] }
        return Set(ids.map { PluginID($0) })
    }

    /// Keeps a record that exists but cannot be decoded instead of silently
    /// overwriting it, so what the user removed before the damage can still be
    /// read from the `.unreadable` copy.
    private func setAsideUnreadableRemovalRecord() throws {
        guard fileManager.fileExists(atPath: removedBundledPluginsURL.path),
              (try? decoder.decode([String].self, from: Data(contentsOf: removedBundledPluginsURL))) == nil
        else { return }
        if fileManager.fileExists(atPath: unreadableRemovalRecordURL.path) {
            try fileManager.removeItem(at: unreadableRemovalRecordURL)
        }
        try fileManager.moveItem(at: removedBundledPluginsURL, to: unreadableRemovalRecordURL)
    }

    /// Best effort: the package is already gone, and leftover state of an
    /// uninstalled plugin is never read again.
    private func removeState(of pluginID: PluginID) {
        guard let stateDirectories, (try? validatePathComponent(pluginID.rawValue)) != nil else { return }
        try? fileManager.removeItem(at: stateDirectories.pluginDirectory(pluginID: pluginID.rawValue))
    }

    func stageUninstall(_ pluginID: PluginID) throws {
        try validatePathComponent(pluginID.rawValue)
        let pluginDirectory = rootURL.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        let record = try installationRecord(at: pluginDirectory)
        let descriptor = try loadPackage(at: versionDirectory(
            pluginDirectory: pluginDirectory,
            version: record.activeVersion
        ))
        guard !descriptor.pluginManifest.modules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginPackageStoreError.requiredPluginCannotBeUninstalled(pluginID)
        }
        try write(
            record.with(status: .uninstallPending),
            to: pluginDirectory.appendingPathComponent("installation.json")
        )
    }

    /// Recovery path for an unreadable or retired active package. The
    /// installation record is deliberately sufficient to schedule removal
    /// without accepting the package's manifest.
    func stageInvalidPackageUninstall(_ pluginID: PluginID) throws {
        try validatePathComponent(pluginID.rawValue)
        let pluginDirectory = rootURL.appendingPathComponent(pluginID.rawValue, isDirectory: true)
        let record = try installationRecord(at: pluginDirectory)
        try write(
            record.with(status: .uninstallPending),
            to: pluginDirectory.appendingPathComponent("installation.json")
        )
    }

    private func validatePackage(
        _ descriptor: DeclarativePluginDescriptor,
        at packageURL: URL,
        origin: PluginInstallationOrigin,
        marketplace: PluginMarketplaceProvenance? = nil,
        disk: PluginDiskProvenance? = nil
    ) throws {
        try validateOfficialTrustPolicy(descriptor.pluginManifest)
        _ = try ValidatedPluginCatalog(manifests: [descriptor.pluginManifest], hostVersion: hostVersion)
        try verifier.verify(packageAt: packageURL, manifest: descriptor.pluginManifest, origin: origin)
        if origin == .community {
            try validateCommunityContent(descriptor.id, at: packageURL, marketplace: marketplace, disk: disk)
        }
        try validateLaunchResources(descriptor, at: packageURL)
        _ = try MacPluginUIIconLoader.load(descriptor, at: packageURL)
        try MacPluginWebContent.validateEntries(descriptor, at: packageURL)
    }

    /// A community package has no publisher signature, so its integrity is
    /// the file digest recorded when the user approved it. Any changed,
    /// added, or removed file makes the package unloadable.
    private func validateCommunityContent(
        _ pluginID: PluginID,
        at packageURL: URL,
        marketplace: PluginMarketplaceProvenance?,
        disk: PluginDiskProvenance?
    ) throws {
        // Exactly one source owns the approval; local bytes must never acquire
        // repository update provenance merely by sharing the plugin ID.
        guard (marketplace != nil) != (disk != nil),
              let expectedDigest = marketplace?.contentDigest ?? disk?.contentDigest else {
            throw PluginPackageStoreError.communityContentChanged(pluginID)
        }
        let digest: String
        do {
            digest = try PluginPackageSignature.contentDigest(packageAt: packageURL, fileManager: fileManager)
        } catch {
            throw PluginPackageStoreError.communityContentChanged(pluginID)
        }
        guard digest == expectedDigest else {
            throw PluginPackageStoreError.communityContentChanged(pluginID)
        }
    }

    /// Every packaged executable must be a regular, executable file inside
    /// the package; symbolic links are refused so a package cannot point the
    /// host at a program outside its signed contents.
    private func validateLaunchResources(_ descriptor: DeclarativePluginDescriptor, at packageURL: URL) throws {
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        for server in descriptor.languageServers {
            guard case .packaged(let relativePath) = server.launch else { continue }
            let executableURL = root.appendingPathComponent(relativePath).standardizedFileURL
            let values = try? executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard executableURL.path.hasPrefix(root.path + "/"),
                  values?.isSymbolicLink != true,
                  values?.isRegularFile == true,
                  fileManager.isExecutableFile(atPath: executableURL.path) else {
                throw PluginPackageStoreError.languageServerLaunchMissing(descriptor.id, relativePath)
            }
        }
        for buildSystem in descriptor.buildSystems where buildSystem.declaresProvider {
            try validateBuildProviderLaunch(buildSystem.id, of: descriptor, at: root)
        }
    }

    /// Expands the provider launch with throwaway directories (nothing is
    /// created) and checks every package path it points at, so a broken
    /// package is refused here rather than at its first model load. A
    /// provider that shares a language server is checked with that server.
    private func validateBuildProviderLaunch(
        _ buildSystemID: String,
        of descriptor: DeclarativePluginDescriptor,
        at root: URL
    ) throws {
        let missing = { (path: String) in
            PluginPackageStoreError.buildProviderLaunchMissing(descriptor.id, buildSystemID: buildSystemID, path: path)
        }
        guard let launchPlanner else { throw missing("provider") }
        let unused = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-provider-validation", isDirectory: true)
        let plan: DeclarativeLanguageServerLaunchPlan
        do {
            plan = try launchPlanner.buildProviderLaunchPlan(
                manifest: descriptor.normalizedManifest,
                buildSystemID: buildSystemID,
                request: DeclarativeLanguageServerLaunchRequest(
                    pluginDirectory: root,
                    stateDirectory: unused.appendingPathComponent("state", isDirectory: true),
                    workspaceStateDirectory: unused.appendingPathComponent("workspace", isDirectory: true),
                    architecture: MacPluginLanguageServerLaunchResolver.hostArchitecture,
                    settings: [:]
                )
            )
        } catch let rejection as DeclarativePluginRejection {
            throw PluginPackageStoreError.declarationRejected(descriptor.id, rejection)
        }
        guard plan.buildProvider?.languageServer == nil else { return }
        for relativePath in plan.requiredPackagePaths where !isPackageEntry(relativePath, in: root) {
            throw missing(relativePath)
        }
        var executables: [String] = []
        if case .packaged(let path)? = plan.executable { executables.append(path) }
        if let path = plan.packagedRuntimePath { executables.append(path) }
        for relativePath in executables {
            let url = root.appendingPathComponent(relativePath).standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard isPackageEntry(relativePath, in: root),
                  values?.isRegularFile == true,
                  fileManager.isExecutableFile(atPath: url.path) else {
                throw missing(relativePath)
            }
        }
    }

    /// The path exists inside the package and no component of it is a
    /// symbolic link, the same rule the launch resolver applies at start.
    private func isPackageEntry(_ relativePath: String, in root: URL) -> Bool {
        var current = root
        for component in relativePath.split(separator: "/") {
            guard component != "..", component != "." else { return false }
            current.appendPathComponent(String(component))
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
        }
        return current.standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    private func validateOfficialTrustPolicy(_ manifest: PluginManifest) throws {
        guard let trusted = OfficialPluginCatalog.entry(for: manifest.id) else { return }
        guard manifest.vendor.signatureRequirement == trusted.signatureRequirement else {
            throw PluginPackageStoreError.officialSignatureRequirementMismatch(manifest.id)
        }
    }

    private func loadPackage(at packageURL: URL) throws -> DeclarativePluginDescriptor {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw PluginPackageStoreError.invalidPackageDirectory
        }
        let data = try Data(contentsOf: packageURL.appendingPathComponent("plugin.json"), options: .mappedIfSafe)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schemaVersion = object?["schemaVersion"] as? Int
        let pluginID = (object?["id"] as? String).flatMap { $0.isEmpty ? nil : PluginID($0) }
        if schemaVersion == PluginManifest.currentSchemaVersion,
           let legacy = try? decoder.decode(PluginManifest.self, from: data),
           legacy.entrypoint.kind == .nativeBundle {
            throw PluginPackageStoreError.legacyNativePackage(legacy.id, legacy.version)
        }
        do {
            return try validator.validate(manifest: data)
        } catch let rejection as DeclarativePluginRejection {
            throw PluginPackageStoreError.declarationRejected(pluginID, rejection)
        }
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

/// Decides whether a package's origin can be trusted. Declarative packages
/// contain no host-loaded code, so trust comes from the publisher signature
/// over every file, or from the host's own sealed installation.
struct MacOfficialPluginSignatureVerifier: PluginPackageSignatureVerifying {
    /// Development builds accept unsigned packages installed from disk so
    /// plugin authors can test without the publisher key. Release builds never
    /// load them; the installation record keeps the origin explicit.
    static var allowsLocalDevelopmentPackagesByDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private let trustedPublisherKeys: [String: Curve25519.Signing.PublicKey]?
    private let allowsLocalDevelopmentPackages: Bool
    private let hostBundleURL: URL

    init(
        trustedPublisherKeys: [String: Curve25519.Signing.PublicKey]? = nil,
        allowsLocalDevelopmentPackages: Bool = Self.allowsLocalDevelopmentPackagesByDefault,
        hostBundleURL: URL = Bundle.main.bundleURL
    ) {
        self.trustedPublisherKeys = trustedPublisherKeys
        self.allowsLocalDevelopmentPackages = allowsLocalDevelopmentPackages
        self.hostBundleURL = hostBundleURL
    }

    /// The host's trust policy wins over the package's own declaration, so an
    /// official plugin cannot downgrade the signature it must carry.
    static func signatureRequirement(for manifest: PluginManifest) -> PluginSignatureRequirement {
        OfficialPluginCatalog.entry(for: manifest.id)?.signatureRequirement
            ?? manifest.vendor.signatureRequirement
    }

    /// An unsigned package counts as a development package only when its
    /// trust model calls for a publisher signature. Packages trusted through
    /// the host's own installation never carry one and keep their origin.
    static func isUnsignedDevelopmentPackage(at packageURL: URL, manifest: PluginManifest) -> Bool {
        signatureRequirement(for: manifest) == .publisherPackage
            && !hasPackageSignature(at: packageURL)
    }

    static func hasPackageSignature(at packageURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(PluginPackageSignature.signatureFileName).path
        )
    }

    func verify(
        packageAt packageURL: URL,
        manifest: PluginManifest,
        origin: PluginInstallationOrigin
    ) throws {
        // Unsigned packages are community packages and nothing else: any
        // other origin or a host-pinned official ID needs a real signature.
        // Rust Core already refuses `none` for the official namespace.
        if manifest.vendor.signatureRequirement == .unsigned || origin == .community {
            guard manifest.vendor.signatureRequirement == .unsigned,
                  origin == .community,
                  OfficialPluginCatalog.entry(for: manifest.id) == nil else {
                throw PluginPackageStoreError.unsignedPackageNotAllowed(manifest.id)
            }
            if Self.hasPackageSignature(at: packageURL) {
                try verifyPublisherPackageSignature(packageAt: packageURL, manifest: manifest)
            }
            return
        }
        if origin == .localDevelopment,
           Self.isUnsignedDevelopmentPackage(at: packageURL, manifest: manifest) {
            guard allowsLocalDevelopmentPackages else {
                throw PluginPackageStoreError.developmentPackageNotAllowed(manifest.id)
            }
            return
        }

        // A signature document is verified whenever it is present, even for
        // packages trusted through the host installation, so a forged or
        // damaged document is never silently ignored.
        let signatureRequirement = Self.signatureRequirement(for: manifest)
        if signatureRequirement == .publisherPackage || Self.hasPackageSignature(at: packageURL) {
            try verifyPublisherPackageSignature(packageAt: packageURL, manifest: manifest)
        }
        if signatureRequirement == .publisherPackage {
            return
        }
        // `sameTeamAsHost` has no code signature to compare any more: the
        // package is trusted only inside the host bundle, whose code signature
        // seals every resource it contains.
        let hostBundlePath = hostBundleURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let packagePath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard origin == .bundled, packagePath.hasPrefix(hostBundlePath) else {
            throw PluginPackageStoreError.hostSealRequired(manifest.id)
        }
    }

    private func verifyPublisherPackageSignature(
        packageAt packageURL: URL,
        manifest: PluginManifest
    ) throws {
        guard Self.hasPackageSignature(at: packageURL) else {
            throw PluginPackageStoreError.missingPackageSignature
        }
        let document: PluginPackageSignature.Document
        do {
            document = try PluginPackageSignature.read(from: packageURL)
        } catch {
            throw PluginPackageStoreError.invalidPackageSignature("The signature document could not be decoded.")
        }
        let trustedKeys: [String: Curve25519.Signing.PublicKey]
        if let trustedPublisherKeys {
            trustedKeys = trustedPublisherKeys
        } else {
            do {
                trustedKeys = try PluginPackageSignature.trustedPublisherKeys()
            } catch {
                throw PluginPackageStoreError.invalidPackageSignature("The embedded public key is invalid.")
            }
        }
        do {
            try PluginPackageSignature.verify(
                packageAt: packageURL,
                pluginID: manifest.id.rawValue,
                pluginVersion: manifest.version.description,
                document: document,
                trustedKeys: trustedKeys
            )
        } catch {
            throw PluginPackageStoreError.invalidPackageSignature(error.localizedDescription)
        }
    }
}
