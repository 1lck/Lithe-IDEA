import Foundation

public struct PluginID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A plugin ID must not be empty.")
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard !rawValue.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A plugin ID must not be empty."
            )
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PluginVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        precondition(major >= 0 && minor >= 0 && patch >= 0, "Version components must not be negative.")
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let version = PluginVersion(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a semantic version with major.minor.patch components."
            )
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct PluginHostCompatibility: Equatable, Codable, Sendable {
    public let minimum: PluginVersion
    public let maximumExclusive: PluginVersion?

    public init(minimum: PluginVersion, maximumExclusive: PluginVersion? = nil) {
        self.minimum = minimum
        self.maximumExclusive = maximumExclusive
    }

    public func contains(_ hostVersion: PluginVersion) -> Bool {
        guard hostVersion >= minimum else { return false }
        return maximumExclusive.map { hostVersion < $0 } ?? true
    }
}

public enum PluginSignatureRequirement: String, Codable, Sendable {
    case sameTeamAsHost
    case publisherPackage
    /// Community package without a Lithe signature (`"none"`). Hosts accept it
    /// only from a third-party marketplace source after the archive matched
    /// the index checksum and the user confirmed the install review.
    case unsigned = "none"
}

public struct PluginVendor: Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let signatureRequirement: PluginSignatureRequirement

    public init(
        id: String,
        displayName: String,
        signatureRequirement: PluginSignatureRequirement
    ) {
        self.id = id
        self.displayName = displayName
        self.signatureRequirement = signatureRequirement
    }
}

public enum PluginEntrypointKind: String, Codable, Sendable {
    case builtIn
    /// Retired in-process Swift bundle. Still decoded so an installed legacy
    /// package can be recognized and replaced, but never loaded.
    case nativeBundle
    /// Data-only package whose processes the host launches itself; see
    /// shared/contracts/plugins/v1/README.md.
    case declarative
}

public struct PluginEntrypoint: Equatable, Codable, Sendable {
    public let kind: PluginEntrypointKind
    public let targetName: String?
    public let bundleIdentifier: String?
    public let principalClass: String?
    public let bundlePath: String?

    public init(
        kind: PluginEntrypointKind,
        targetName: String? = nil,
        bundleIdentifier: String? = nil,
        principalClass: String? = nil,
        bundlePath: String? = nil
    ) {
        self.kind = kind
        self.targetName = targetName
        self.bundleIdentifier = bundleIdentifier
        self.principalClass = principalClass
        self.bundlePath = bundlePath
    }

    public static func builtIn(targetName: String) -> Self {
        Self(kind: .builtIn, targetName: targetName)
    }

    public static let declarative = Self(kind: .declarative)
}

public struct PluginModuleDeclaration: Equatable, Codable, Sendable {
    public let manifest: ModuleManifest
    public let contributions: [ModuleContribution]

    public init(manifest: ModuleManifest, contributions: [ModuleContribution] = []) {
        self.manifest = manifest
        self.contributions = contributions.sorted {
            ($0.placement.rawValue, $0.order, $0.id)
                < ($1.placement.rawValue, $1.order, $1.id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case scope
        case defaultState
        case activationPolicy
        case sleepPolicy
        case moduleDependencies
        case capabilityDependencies
        case providedCapabilities
        case contributions
        case required
    }

    private struct SleepPolicyValue: Codable {
        let kind: String
        let afterSeconds: TimeInterval?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = ModuleID(try container.decode(String.self, forKey: .id))
        let moduleDependencies = try container.decodeIfPresent(
            [String].self,
            forKey: .moduleDependencies
        ) ?? []
        let capabilityDependencies = try container.decodeIfPresent(
            [String].self,
            forKey: .capabilityDependencies
        ) ?? []
        let providedCapabilities = try container.decode(
            [String].self,
            forKey: .providedCapabilities
        )
        let sleepValue = try container.decode(SleepPolicyValue.self, forKey: .sleepPolicy)
        let sleepPolicy: ModuleSleepPolicy
        switch sleepValue.kind {
        case "never":
            guard sleepValue.afterSeconds == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sleepPolicy,
                    in: container,
                    debugDescription: "A never sleep policy must not include afterSeconds."
                )
            }
            sleepPolicy = .never
        case "whenIdle":
            guard let interval = sleepValue.afterSeconds, interval > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sleepPolicy,
                    in: container,
                    debugDescription: "A whenIdle sleep policy requires a positive afterSeconds value."
                )
            }
            sleepPolicy = .whenIdle(afterSeconds: interval)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .sleepPolicy,
                in: container,
                debugDescription: "Unsupported module sleep policy."
            )
        }
        manifest = ModuleManifest(
            id: id,
            displayName: try container.decode(String.self, forKey: .displayName),
            scope: try container.decode(ModuleScope.self, forKey: .scope),
            defaultState: try container.decode(ModuleDefaultState.self, forKey: .defaultState),
            activationPolicy: try container.decode(ModuleActivationPolicy.self, forKey: .activationPolicy),
            sleepPolicy: sleepPolicy,
            dependencies: Set(moduleDependencies.map { .module(ModuleID($0)) })
                .union(capabilityDependencies.map { .capability(ModuleCapabilityID($0)) }),
            providedCapabilities: Set(providedCapabilities.map { ModuleCapabilityID($0) }),
            isRequired: try container.decode(Bool.self, forKey: .required)
        )
        contributions = try container.decodeIfPresent(
            [ModuleContribution].self,
            forKey: .contributions
        )?.sorted {
            ($0.placement.rawValue, $0.order, $0.id)
                < ($1.placement.rawValue, $1.order, $1.id)
        } ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifest.id.rawValue, forKey: .id)
        try container.encode(manifest.displayName, forKey: .displayName)
        try container.encode(manifest.scope, forKey: .scope)
        try container.encode(manifest.defaultState, forKey: .defaultState)
        try container.encode(manifest.activationPolicy, forKey: .activationPolicy)
        let sleepValue: SleepPolicyValue
        switch manifest.sleepPolicy {
        case .never:
            sleepValue = SleepPolicyValue(kind: "never", afterSeconds: nil)
        case .whenIdle(let interval):
            sleepValue = SleepPolicyValue(kind: "whenIdle", afterSeconds: interval)
        }
        try container.encode(sleepValue, forKey: .sleepPolicy)
        let moduleDependencies = manifest.dependencies.compactMap { dependency -> String? in
            guard case .module(let id) = dependency else { return nil }
            return id.rawValue
        }.sorted()
        let capabilityDependencies = manifest.dependencies.compactMap { dependency -> String? in
            guard case .capability(let id) = dependency else { return nil }
            return id.rawValue
        }.sorted()
        try container.encode(moduleDependencies, forKey: .moduleDependencies)
        try container.encode(capabilityDependencies, forKey: .capabilityDependencies)
        try container.encode(
            manifest.providedCapabilities.map(\.rawValue).sorted(),
            forKey: .providedCapabilities
        )
        try container.encode(contributions, forKey: .contributions)
        try container.encode(manifest.isRequired, forKey: .required)
    }
}

/// Inert inputs and existing project-local paths for a language's dependency tree.
/// A management entry can be a file name or a workspace-relative suffix.
public struct LanguageDependencyDeclaration: Equatable, Codable, Sendable {
    public let managementFileNames: [String]
    public let projectDependencyPaths: [String]
    public let projectBinaryPaths: [String]

    public init(
        managementFileNames: [String] = [],
        projectDependencyPaths: [String] = [],
        projectBinaryPaths: [String] = []
    ) {
        self.managementFileNames = Self.normalized(managementFileNames, lowercased: true)
        self.projectDependencyPaths = Self.normalized(projectDependencyPaths)
        self.projectBinaryPaths = Self.normalized(projectBinaryPaths)
    }

    private static func normalized(_ values: [String], lowercased: Bool = false) -> [String] {
        Set(values.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return lowercased ? trimmed.lowercased() : trimmed
        }
            .filter { !$0.isEmpty }).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case managementFileNames, projectDependencyPaths, projectBinaryPaths
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            managementFileNames: try values.decodeIfPresent([String].self, forKey: .managementFileNames) ?? [],
            projectDependencyPaths: try values.decodeIfPresent([String].self, forKey: .projectDependencyPaths) ?? [],
            projectBinaryPaths: try values.decodeIfPresent([String].self, forKey: .projectBinaryPaths) ?? []
        )
    }
}

/// A process-backed feature of a language that the host implements itself.
///
/// A plugin that owns a language switches the host's built-in tools for it
/// off. It hands a feature back by declaring the capability on the host
/// integration of its language server, which also supplies the files that
/// implementation needs.
public enum LanguageHostCapability: String, Codable, CaseIterable, Sendable {
    case debug
    case run
    case testing
}

public extension Sequence where Element == LanguageSupportDeclaration {
    /// Languages for which only a plugin module may provide `capability`.
    /// The host must not run its built-in implementation for them, even when
    /// that module is missing or disabled.
    func languageIDs(requiringExtensionFor capability: LanguageHostCapability) -> Set<String> {
        Set(lazy.filter { !$0.hostCapabilities.contains(capability) }.map(\.id))
    }
}

/// Recognizes a language and routes its independently activated capabilities
/// without loading the plugin Bundle.
public struct LanguageSupportDeclaration: Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let fileExtensions: [String]
    public let fileNames: [String]
    public let projectFileNames: [String]
    public let dependencies: LanguageDependencyDeclaration?
    public let virtualDocumentSchemes: [String]
    public let languageServerModuleID: ModuleID?
    public let executionModuleID: ModuleID?
    public let testingModuleID: ModuleID?
    public let debugModuleID: ModuleID?
    /// Features the host's own implementation provides for this language, as
    /// declared by the plugin's host integration. Never overlaps with a
    /// capability one of the modules above provides.
    public let hostCapabilities: Set<LanguageHostCapability>

    public init(
        id: String,
        displayName: String,
        fileExtensions: [String] = [],
        fileNames: [String] = [],
        projectFileNames: [String] = [],
        dependencies: LanguageDependencyDeclaration? = nil,
        virtualDocumentSchemes: [String] = [],
        languageServerModuleID: ModuleID? = nil,
        executionModuleID: ModuleID? = nil,
        testingModuleID: ModuleID? = nil,
        debugModuleID: ModuleID? = nil,
        hostCapabilities: Set<LanguageHostCapability> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = Self.normalized(fileExtensions, removingLeadingDot: true)
        self.fileNames = Self.normalized(fileNames)
        self.projectFileNames = Self.normalized(projectFileNames)
        self.dependencies = dependencies
        self.virtualDocumentSchemes = Self.normalized(virtualDocumentSchemes)
        self.languageServerModuleID = languageServerModuleID
        self.executionModuleID = executionModuleID
        self.testingModuleID = testingModuleID
        self.debugModuleID = debugModuleID
        self.hostCapabilities = hostCapabilities
    }

    public var moduleIDs: [ModuleID] {
        [languageServerModuleID, executionModuleID, testingModuleID, debugModuleID].compactMap { $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, fileExtensions, fileNames, projectFileNames
        case dependencies, virtualDocumentSchemes
        case languageServerModuleID, executionModuleID, testingModuleID, debugModuleID
        case hostCapabilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            displayName: try values.decode(String.self, forKey: .displayName),
            fileExtensions: try values.decodeIfPresent([String].self, forKey: .fileExtensions) ?? [],
            fileNames: try values.decodeIfPresent([String].self, forKey: .fileNames) ?? [],
            projectFileNames: try values.decodeIfPresent([String].self, forKey: .projectFileNames) ?? [],
            dependencies: try values.decodeIfPresent(LanguageDependencyDeclaration.self, forKey: .dependencies),
            virtualDocumentSchemes: try values.decodeIfPresent([String].self, forKey: .virtualDocumentSchemes) ?? [],
            languageServerModuleID: try values.decodeIfPresent(ModuleID.self, forKey: .languageServerModuleID),
            executionModuleID: try values.decodeIfPresent(ModuleID.self, forKey: .executionModuleID),
            testingModuleID: try values.decodeIfPresent(ModuleID.self, forKey: .testingModuleID),
            debugModuleID: try values.decodeIfPresent(ModuleID.self, forKey: .debugModuleID),
            hostCapabilities: try values.decodeIfPresent(
                Set<LanguageHostCapability>.self,
                forKey: .hostCapabilities
            ) ?? []
        )
    }

    /// Stable output: the capabilities are written in sorted order, and
    /// omitted when there are none so existing encodings do not change.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(fileExtensions, forKey: .fileExtensions)
        try values.encode(fileNames, forKey: .fileNames)
        try values.encode(projectFileNames, forKey: .projectFileNames)
        try values.encodeIfPresent(dependencies, forKey: .dependencies)
        try values.encode(virtualDocumentSchemes, forKey: .virtualDocumentSchemes)
        try values.encodeIfPresent(languageServerModuleID, forKey: .languageServerModuleID)
        try values.encodeIfPresent(executionModuleID, forKey: .executionModuleID)
        try values.encodeIfPresent(testingModuleID, forKey: .testingModuleID)
        try values.encodeIfPresent(debugModuleID, forKey: .debugModuleID)
        if !hostCapabilities.isEmpty {
            try values.encode(
                hostCapabilities.sorted { $0.rawValue < $1.rawValue },
                forKey: .hostCapabilities
            )
        }
    }

    public func handles(fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent.lowercased()
        return fileExtensions.contains(fileURL.pathExtension.lowercased())
            || fileNames.contains(fileName)
    }

    public func recognizesProject(fileNames: some Sequence<String>) -> Bool {
        let candidates = Set(fileNames.map { $0.lowercased() })
        return projectFileNames.contains { candidates.contains($0) }
    }

    private static func normalized(
        _ values: [String],
        removingLeadingDot: Bool = false
    ) -> [String] {
        Set(values.compactMap { value -> String? in
            var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if removingLeadingDot, normalized.hasPrefix(".") {
                normalized.removeFirst()
            }
            return normalized.isEmpty ? nil : normalized
        }).sorted()
    }
}

public struct PluginManifest: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentAPIVersion = 1
    /// `plugin.json` schema of a declarative package (plugin contract v1).
    public static let declarativeSchemaVersion = 2
    /// Declarative plugin API levels this host supports. Rust Core enforces
    /// the same list (`SUPPORTED_PLUGIN_API_VERSIONS`) when it validates a
    /// manifest; the Lithe application version plays no part.
    public static let supportedDeclarativeAPIVersions: Set<Int> = [1, 2, 3]
    /// Capability versions of API level 3 this host runs, sent to Rust Core
    /// as `hostCapabilities`. Core then refuses, and the marketplace hides, a
    /// level 3 plugin that requires anything else. Validating a capability is
    /// not running it, so an entry is added only with its host support.
    public static let hostCapabilities: [String: [Int]] = [
        "buildProviders": [1],
        "buildSystems": [1],
        "executionProviders": [1],
        "languageServers": [1],
        "languages": [1],
        "serverProcess": [1],
        "settings": [1],
        "ui": [1, 2]
    ]

    public let schemaVersion: Int
    public let id: PluginID
    public let displayName: String
    public let version: PluginVersion
    public let apiVersion: Int
    public let hostCompatibility: PluginHostCompatibility
    public let vendor: PluginVendor
    public let entrypoint: PluginEntrypoint
    public let modules: [PluginModuleDeclaration]
    public let languageSupports: [LanguageSupportDeclaration]?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: PluginID,
        displayName: String,
        version: PluginVersion,
        apiVersion: Int = currentAPIVersion,
        hostCompatibility: PluginHostCompatibility,
        vendor: PluginVendor,
        entrypoint: PluginEntrypoint,
        modules: [PluginModuleDeclaration],
        languageSupports: [LanguageSupportDeclaration] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.version = version
        self.apiVersion = apiVersion
        self.hostCompatibility = hostCompatibility
        self.vendor = vendor
        self.entrypoint = entrypoint
        self.modules = modules.sorted { $0.manifest.id < $1.manifest.id }
        let sortedLanguageSupports = languageSupports.sorted { $0.id < $1.id }
        self.languageSupports = sortedLanguageSupports.isEmpty ? nil : sortedLanguageSupports
    }
}

public enum PluginInstallationOrigin: String, Codable, Sendable {
    case bundled
    case marketplace
    /// An unsigned package installed from disk by a development build. Release
    /// builds reject this origin instead of loading its code.
    case localDevelopment
    /// A community package installed from a repository or local disk after
    /// the user confirmed its permissions and programs.
    case community
}

/// A user-selected local package, without any claim of repository verification.
/// The content digest binds the approval to the installed files; directories
/// have no archive checksum. This record is never a marketplace update source.
public struct PluginDiskProvenance: Equatable, Codable, Sendable {
    public let fileName: String
    public let archiveSHA256: String?
    public let contentDigest: String
    public let approvedPrograms: [String]

    public init(fileName: String, archiveSHA256: String?, contentDigest: String, approvedPrograms: [String]) {
        self.fileName = fileName
        self.archiveSHA256 = archiveSHA256
        self.contentDigest = contentDigest
        self.approvedPrograms = approvedPrograms
    }
}

/// Where a marketplace installation came from and what the user approved.
/// Updates are only offered from the same source, and an update that starts
/// programs outside `approvedPrograms` needs a new confirmation.
public struct PluginMarketplaceProvenance: Equatable, Codable, Sendable {
    public let sourceID: String
    public let sourceName: String
    /// Plugin repository listed by the index entry, for issue reports.
    public let repository: String
    public let archiveSHA256: String
    /// Digest of the installed files, rechecked whenever the package is loaded.
    public let contentDigest: String
    /// Canonical JSON of each approved program from `plugins.marketplace.installReview`.
    public let approvedPrograms: [String]

    public init(
        sourceID: String,
        sourceName: String,
        repository: String,
        archiveSHA256: String,
        contentDigest: String,
        approvedPrograms: [String]
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.repository = repository
        self.archiveSHA256 = archiveSHA256
        self.contentDigest = contentDigest
        self.approvedPrograms = approvedPrograms
    }
}

public enum PluginInstallationStatus: String, Codable, Sendable {
    case installed
    case updateStaged
    case uninstallPending
    /// The user removed a plugin that ships inside the application. Its files
    /// stay in the read-only app bundle, but the host does not register it
    /// until the user restores it.
    case removed
}

public struct PluginInstallationRecord: Equatable, Codable, Sendable {
    public let pluginID: PluginID
    public let activeVersion: PluginVersion
    public let previousVersion: PluginVersion?
    public let origin: PluginInstallationOrigin
    /// Origin of `previousVersion`. Each installed version keeps its own trust
    /// origin so a rollback verifies the restored package by how it was
    /// installed. Records written before this field existed decode as `nil`
    /// and fall back to `origin`.
    public let previousOrigin: PluginInstallationOrigin?
    public let status: PluginInstallationStatus
    /// Marketplace provenance of the active and previous versions. Records
    /// written before the marketplace existed decode as `nil`.
    public let marketplace: PluginMarketplaceProvenance?
    public let previousMarketplace: PluginMarketplaceProvenance?
    /// Local disk approvals are separate from repository provenance. Missing
    /// fields in records from earlier versions decode as nil.
    public let disk: PluginDiskProvenance?
    public let previousDisk: PluginDiskProvenance?

    public init(
        pluginID: PluginID,
        activeVersion: PluginVersion,
        previousVersion: PluginVersion? = nil,
        origin: PluginInstallationOrigin,
        previousOrigin: PluginInstallationOrigin? = nil,
        status: PluginInstallationStatus = .installed,
        marketplace: PluginMarketplaceProvenance? = nil,
        previousMarketplace: PluginMarketplaceProvenance? = nil,
        disk: PluginDiskProvenance? = nil,
        previousDisk: PluginDiskProvenance? = nil
    ) {
        self.pluginID = pluginID
        self.activeVersion = activeVersion
        self.previousVersion = previousVersion
        self.origin = origin
        self.previousOrigin = previousOrigin
        self.status = status
        self.marketplace = marketplace
        self.previousMarketplace = previousMarketplace
        self.disk = disk
        self.previousDisk = previousDisk
    }

    /// The same record with another status; every other field is preserved.
    public func with(status: PluginInstallationStatus) -> PluginInstallationRecord {
        PluginInstallationRecord(
            pluginID: pluginID,
            activeVersion: activeVersion,
            previousVersion: previousVersion,
            origin: origin,
            previousOrigin: previousOrigin,
            status: status,
            marketplace: marketplace,
            previousMarketplace: previousMarketplace,
            disk: disk,
            previousDisk: previousDisk
        )
    }
}
