import Foundation

// Note: 插件市场的来源、信任与安装确认见 .agents/notes/implemented/feature/2026-10-12-plugin-marketplace.md

/// Who maintains a marketplace source. Only the host's built-in default
/// source is official; every source a user adds is third-party.
public enum PluginMarketplaceSourceKind: String, Codable, Sendable {
    case official
    case thirdParty
}

/// Index validated by `plugins.marketplace.validateIndex` for one platform.
public struct PluginMarketplaceIndex: Equatable, Codable, Sendable {
    public let plugins: [PluginMarketplaceEntry]
    public let rejected: [PluginMarketplaceRejectedEntry]

    public init(plugins: [PluginMarketplaceEntry], rejected: [PluginMarketplaceRejectedEntry]) {
        self.plugins = plugins
        self.rejected = rejected
    }
}

public struct PluginMarketplaceRejectedEntry: Equatable, Codable, Sendable {
    public let id: String?
    public let error: DeclarativePluginRejectionPayload
}

/// Codable form of a `plugin.*` refusal inside a successful Core outcome.
public struct DeclarativePluginRejectionPayload: Equatable, Codable, Sendable {
    public let code: String
    public let message: String
    public let field: String?

    public var rejection: DeclarativePluginRejection {
        DeclarativePluginRejection(code: code, message: message, field: field)
    }
}

/// One normalized index entry. Versions are newest first.
public struct PluginMarketplaceEntry: Equatable, Codable, Sendable, Identifiable {
    public struct Version: Equatable, Codable, Sendable {
        public let version: String
        public let pluginAPIVersion: Int
        public let releaseDate: String
        public let platforms: [String]

        public init(version: String, pluginAPIVersion: Int, releaseDate: String, platforms: [String]) {
            self.version = version
            self.pluginAPIVersion = pluginAPIVersion
            self.releaseDate = releaseDate
            self.platforms = platforms
        }
    }

    public let id: String
    public let name: String
    public let author: String
    public let repository: String
    public let homepage: String?
    public let description: String
    /// Translations of `description` keyed by language tag (`zh-Hans`).
    public let localizedDescriptions: [String: String]?
    public let tags: [String]
    public let license: String
    public let icon: String?
    /// Platforms of the newest version.
    public let platforms: [String]
    public let latestVersion: String
    public let latestReleaseDate: String
    public let availability: PluginMarketplaceAvailability
    public let versions: [Version]

    public init(
        id: String,
        name: String,
        author: String,
        repository: String,
        homepage: String?,
        description: String,
        localizedDescriptions: [String: String]? = nil,
        tags: [String],
        license: String,
        icon: String?,
        platforms: [String],
        latestVersion: String,
        latestReleaseDate: String,
        availability: PluginMarketplaceAvailability,
        versions: [Version]
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.repository = repository
        self.homepage = homepage
        self.description = description
        self.localizedDescriptions = localizedDescriptions
        self.tags = tags
        self.license = license
        self.icon = icon
        self.platforms = platforms
        self.latestVersion = latestVersion
        self.latestReleaseDate = latestReleaseDate
        self.availability = availability
        self.versions = versions
    }

    /// The version this host would install. Core may skip newer versions
    /// whose platform or plugin API does not fit, so this can be older than
    /// `latestVersion`; nil when nothing fits.
    public var installableVersion: Version? {
        guard let download = availability.download else { return nil }
        return versions.first { $0.version == download.version }
            ?? Version(
                version: download.version,
                pluginAPIVersion: download.pluginAPIVersion,
                releaseDate: download.releaseDate,
                platforms: platforms
            )
    }

    /// What the catalog shows: the installable version, or the newest one
    /// when none can be installed (with the reason shown alongside).
    public var presentedVersion: Version {
        installableVersion ?? versions.first ?? Version(
            version: latestVersion,
            pluginAPIVersion: 0,
            releaseDate: latestReleaseDate,
            platforms: platforms
        )
    }

    /// The description in `locale`'s language, matched the way the system
    /// matches `.lproj` directories, or `description` when none fits.
    public func description(for locale: Locale) -> String {
        guard let translations = localizedDescriptions, !translations.isEmpty,
              let language = Bundle.preferredLocalizations(
                  // `description` is the English fallback, so an unmatched
                  // language must not pick an arbitrary translation.
                  from: ["en"] + translations.keys.sorted(),
                  forPreferences: [locale.identifier]
              ).first else { return description }
        return translations[language] ?? description
    }
}

/// Whether this host can install the entry, and which archive it would use.
public enum PluginMarketplaceAvailability: Equatable, Codable, Sendable {
    case available(PluginMarketplaceDownload)
    /// `code` is `plugin.index.platformUnsupported` or `plugin.index.apiUnsupported`.
    case unsupported(code: String, platform: String, message: String)

    public var download: PluginMarketplaceDownload? {
        if case .available(let download) = self { download } else { nil }
    }

    private enum CodingKeys: String, CodingKey {
        case status, version, pluginAPIVersion, releaseDate, downloadURL, sha256, code, platform, message
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .status) {
        case "available":
            self = .available(PluginMarketplaceDownload(
                version: try values.decode(String.self, forKey: .version),
                pluginAPIVersion: try values.decode(Int.self, forKey: .pluginAPIVersion),
                releaseDate: try values.decode(String.self, forKey: .releaseDate),
                downloadURL: try values.decode(String.self, forKey: .downloadURL),
                sha256: try values.decode(String.self, forKey: .sha256)
            ))
        case "unsupported":
            self = .unsupported(
                code: try values.decode(String.self, forKey: .code),
                platform: try values.decode(String.self, forKey: .platform),
                message: try values.decode(String.self, forKey: .message)
            )
        case let status:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: values,
                debugDescription: "Unknown availability status \(status)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let download):
            try values.encode("available", forKey: .status)
            try values.encode(download.version, forKey: .version)
            try values.encode(download.pluginAPIVersion, forKey: .pluginAPIVersion)
            try values.encode(download.releaseDate, forKey: .releaseDate)
            try values.encode(download.downloadURL, forKey: .downloadURL)
            try values.encode(download.sha256, forKey: .sha256)
        case .unsupported(let code, let platform, let message):
            try values.encode("unsupported", forKey: .status)
            try values.encode(code, forKey: .code)
            try values.encode(platform, forKey: .platform)
            try values.encode(message, forKey: .message)
        }
    }
}

public struct PluginMarketplaceDownload: Equatable, Codable, Sendable {
    public let version: String
    public let pluginAPIVersion: Int
    public let releaseDate: String
    public let downloadURL: String
    public let sha256: String

    public init(version: String, pluginAPIVersion: Int, releaseDate: String, downloadURL: String, sha256: String) {
        self.version = version
        self.pluginAPIVersion = pluginAPIVersion
        self.releaseDate = releaseDate
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

/// Index location resolved from what the user entered.
public struct PluginMarketplaceSourceResolution: Equatable, Codable, Sendable {
    public let indexURL: String
    public let repository: String?
    public let displayName: String

    public init(indexURL: String, repository: String?, displayName: String) {
        self.indexURL = indexURL
        self.repository = repository
        self.displayName = displayName
    }
}

/// One program the host may start for a plugin, as listed by
/// `plugins.marketplace.installReview`. `json` is the exact Core value, used
/// for approval comparisons; the typed fields serve presentation.
public struct PluginProgram: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case packagedLanguageServer
        case systemLanguageServer
        case runtime
        case run
        case test
        case buildSystem
        case unknown
    }

    public let json: ToolingJSONValue

    public init(json: ToolingJSONValue) {
        self.json = json
    }

    public init(canonicalJSON: String) throws {
        json = try JSONDecoder().decode(ToolingJSONValue.self, from: Data(canonicalJSON.utf8))
    }

    public var kind: Kind { Kind(rawValue: rawKind ?? "") ?? .unknown }
    /// Declared kind, including kinds this host does not describe yet.
    public var rawKind: String? { string("kind") }
    public var languageID: String? { string("languageID") }
    public var path: String? { string("path") }
    public var tool: String? { string("tool") }
    public var commands: [String] { strings("commands") }
    public var arguments: [String] { strings("arguments") }

    /// Command name or project toolchain ID of a run/test executable.
    public var executable: String? {
        guard case .object(let fields) = json, case .object(let executable)? = fields["executable"] else {
            return nil
        }
        if case .string(let command)? = executable["command"] { return command }
        if case .string(let toolchain)? = executable["toolchain"] { return toolchain }
        return nil
    }

    /// Build system ID of a `buildSystem` program.
    public var buildSystemID: String? { string("buildSystemID") }

    /// Executables a `buildSystem` program may resolve, in resolution
    /// order: project wrappers, `$VARIABLE/path` homes, then commands.
    public var buildExecutables: [String] {
        guard case .object(let fields) = json,
              case .object(let invocation)? = fields["invocation"],
              case .array(let executables)? = invocation["executables"] else {
            return []
        }
        var seen = Set<String>()
        return executables.compactMap { value -> String? in
            guard case .object(let executable) = value else { return nil }
            func field(_ key: String) -> String? {
                if case .string(let string)? = executable[key] { string } else { nil }
            }
            let description: String?
            switch field("kind") {
            case "projectFile": description = field("path").map { "./\($0)" }
            case "environment":
                description = field("path").map { path in
                    field("variable").map { "$\($0)/\(path)" } ?? path
                }
            case "command": description = field("command")
            default: description = field("command") ?? field("path")
            }
            guard let description, seen.insert(description).inserted else { return nil }
            return description
        }
    }

    /// Task IDs of a `buildSystem` program.
    public var buildTaskIDs: [String] {
        guard case .object(let fields) = json, case .array(let tasks)? = fields["tasks"] else { return [] }
        return tasks.compactMap { value in
            guard case .object(let task) = value, case .string(let id)? = task["id"] else { return nil }
            return id
        }
    }

    /// Fixed arguments of the language server's validation probe.
    public var validationArguments: [String] { strings("validationArguments") }

    /// Argument template of a run/test program (`arguments`,
    /// `workspaceArguments`, `fileArguments`, `testCaseArguments`), with
    /// conditional elements shown by their value.
    public func argumentTemplate(_ key: String) -> [String] {
        guard case .object(let fields) = json, case .array(let values)? = fields[key] else { return [] }
        return values.compactMap { value in
            switch value {
            case .string(let string): string
            case .object(let element): if case .string(let string)? = element["value"] { string } else { nil }
            default: nil
            }
        }
    }

    /// Stable serialized form stored in the installation record.
    public func canonicalJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(json), as: UTF8.self)
    }

    private func string(_ key: String) -> String? {
        guard case .object(let fields) = json, case .string(let value)? = fields[key] else { return nil }
        return value
    }

    private func strings(_ key: String) -> [String] {
        guard case .object(let fields) = json, case .array(let values)? = fields[key] else { return [] }
        return values.compactMap { value in
            if case .string(let string) = value { string } else { nil }
        }
    }
}

/// What installing a package lets it do.
public struct PluginInstallReview: Equatable, Sendable {
    public let pluginID: String
    public let version: String
    public let permissions: [String]
    public let programs: [PluginProgram]
    /// Programs not covered by the approval of the installed version; all
    /// programs for a first installation.
    public let newPrograms: [PluginProgram]

    public init(
        pluginID: String,
        version: String,
        permissions: [String],
        programs: [PluginProgram],
        newPrograms: [PluginProgram]
    ) {
        self.pluginID = pluginID
        self.version = version
        self.permissions = permissions
        self.programs = programs
        self.newPrograms = newPrograms
    }
}

/// Typed `plugins.marketplace.*` operations owned by Rust Core.
public protocol PluginMarketplaceEvaluating: Sendable {
    func validateIndex(
        _ index: Data,
        sourceKind: PluginMarketplaceSourceKind,
        platform: String
    ) throws -> PluginMarketplaceIndex

    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution

    func installReview(
        manifest: Data,
        expectedID: String?,
        expectedVersion: String?,
        approvedPrograms: [PluginProgram]?
    ) throws -> PluginInstallReview
}
