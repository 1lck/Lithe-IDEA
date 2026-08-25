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
    case nativeBundle
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

/// Inert metadata used to recognize a language project and route host UI to
/// independently activated modules without loading the plugin Bundle.
public struct LanguageSupportDeclaration: Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let fileExtensions: [String]
    public let fileNames: [String]
    public let projectFileNames: [String]
    public let languageServerModuleID: ModuleID?
    public let executionModuleID: ModuleID?
    public let testingModuleID: ModuleID?
    public let debugModuleID: ModuleID?

    public init(
        id: String,
        displayName: String,
        fileExtensions: [String] = [],
        fileNames: [String] = [],
        projectFileNames: [String] = [],
        languageServerModuleID: ModuleID? = nil,
        executionModuleID: ModuleID? = nil,
        testingModuleID: ModuleID? = nil,
        debugModuleID: ModuleID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = Self.normalized(fileExtensions, removingLeadingDot: true)
        self.fileNames = Self.normalized(fileNames)
        self.projectFileNames = Self.normalized(projectFileNames)
        self.languageServerModuleID = languageServerModuleID
        self.executionModuleID = executionModuleID
        self.testingModuleID = testingModuleID
        self.debugModuleID = debugModuleID
    }

    public var moduleIDs: [ModuleID] {
        [languageServerModuleID, executionModuleID, testingModuleID, debugModuleID].compactMap { $0 }
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
}

public enum PluginInstallationStatus: String, Codable, Sendable {
    case installed
    case updateStaged
    case uninstallPending
}

public struct PluginInstallationRecord: Equatable, Codable, Sendable {
    public let pluginID: PluginID
    public let activeVersion: PluginVersion
    public let previousVersion: PluginVersion?
    public let origin: PluginInstallationOrigin
    public let status: PluginInstallationStatus

    public init(
        pluginID: PluginID,
        activeVersion: PluginVersion,
        previousVersion: PluginVersion? = nil,
        origin: PluginInstallationOrigin,
        status: PluginInstallationStatus = .installed
    ) {
        self.pluginID = pluginID
        self.activeVersion = activeVersion
        self.previousVersion = previousVersion
        self.origin = origin
        self.status = status
    }
}
