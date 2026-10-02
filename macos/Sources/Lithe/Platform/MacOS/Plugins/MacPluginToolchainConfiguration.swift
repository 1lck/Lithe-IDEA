import Foundation
import LitheModuleAPI

/// Plugin-owned installation recipe. No language identifier or upstream API
/// shape belongs to the host; fields and commands come from the signed package.
struct MacPluginToolchainConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let pluginID: PluginID
    let toolchains: [Toolchain]
    let languageServers: [LanguageServer]
    let discovery: [String: [String]]?

    struct Toolchain: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let displayName: String
        let metadataURL: URL
        let indexFields: IndexFields
        let os: String
        let architecture: String
        let archiveFormat: String
        let archiveRoot: String
        let executable: String
        let downloadURLTemplate: String
        let validationArguments: [String]
    }

    /// Field mapping for an HTTPS release index containing releases and files.
    struct IndexFields: Codable, Equatable, Sendable {
        let stable: String
        let files: String
        let filename: String
        let os: String
        let architecture: String
        let version: String
        let checksum: String
        let kind: String
        let archiveKind: String
    }

    struct LanguageServer: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let module: String
        let executable: String
        let installCommand: [String]
        let validationArguments: [String]
        let environment: [String: String]
        let runtimeEnvironment: [String: String]
    }

    static func load(from url: URL) throws -> Self {
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    func validate() throws {
        // Version 1 intentionally supports one SDK and at most one server per
        // plugin. Reject additional entries instead of silently ignoring them.
        guard schemaVersion == 1, Self.isSafeComponent(pluginID.rawValue),
              toolchains.count == 1, languageServers.count <= 1 else {
            throw ValidationError.invalidMetadata
        }
        for toolchain in toolchains {
            let sampleURL = URL(string: toolchain.downloadURLTemplate.replacingOccurrences(of: "{filename}", with: "archive"))
            guard Self.isSafeComponent(toolchain.id), !toolchain.kind.isEmpty,
                  !toolchain.displayName.isEmpty, Self.isHTTPS(toolchain.metadataURL),
                  sampleURL.map(Self.isHTTPS) == true,
                  toolchain.downloadURLTemplate.contains("{filename}"),
                  toolchain.os == "darwin",
                  ["host", "arm64", "amd64", "x86_64"].contains(toolchain.architecture),
                  ["tar.gz", "zip"].contains(toolchain.archiveFormat),
                  Self.isSafeRelativePath(toolchain.archiveRoot),
                  Self.isSafeRelativePath(toolchain.executable),
                  !toolchain.validationArguments.isEmpty else { throw ValidationError.invalidMetadata }
        }
        for server in languageServers {
            guard Self.isSafeComponent(server.id), !server.kind.isEmpty, !server.module.isEmpty,
                  Self.isSafeRelativePath(server.executable), !server.installCommand.isEmpty,
                  !server.validationArguments.isEmpty,
                  Array(server.environment.keys).allSatisfy(Self.isEnvironmentKey),
                  Array(server.runtimeEnvironment.keys).allSatisfy(Self.isEnvironmentKey) else { throw ValidationError.invalidMetadata }
        }
        guard (discovery ?? [:]).keys.allSatisfy(Self.isSafeComponent) else { throw ValidationError.invalidMetadata }
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isSafeComponent(String($0)) }
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    static func isEnvironmentKey(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    enum ValidationError: Error { case invalidMetadata }

    var primaryToolchain: Toolchain? { toolchains.first }
    var primaryLanguageServer: LanguageServer? { languageServers.first }
}

struct MacPluginToolchainArchive: Sendable {
    let filename: String
    let version: String
    let checksum: String
    let url: URL

    static func select(from data: Data, toolchain: MacPluginToolchainConfiguration.Toolchain, architecture: String) throws -> Self {
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PluginToolchainError.downloadMetadataFailed
        }
        let fields = toolchain.indexFields
        let expectedArchitecture = toolchain.architecture == "host" ? architecture : toolchain.architecture
        guard expectedArchitecture == architecture else { throw PluginToolchainError.noSupportedToolchain }
        for release in releases where release[fields.stable] as? Bool == true {
            for file in release[fields.files] as? [[String: Any]] ?? [] {
                guard file[fields.os] as? String == toolchain.os,
                      file[fields.architecture] as? String == expectedArchitecture,
                      file[fields.kind] as? String == fields.archiveKind,
                      let filename = file[fields.filename] as? String,
                      filename.hasSuffix("." + toolchain.archiveFormat),
                      MacPluginToolchainConfiguration.isSafeComponent(filename),
                      let version = file[fields.version] as? String,
                      MacPluginToolchainConfiguration.isSafeComponent(version),
                      let checksum = file[fields.checksum] as? String,
                      checksum.count == 64, checksum.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      let url = URL(string: toolchain.downloadURLTemplate.replacingOccurrences(of: "{filename}", with: filename)),
                      MacPluginToolchainConfiguration.isHTTPS(url) else { continue }
                return Self(filename: filename, version: version, checksum: checksum.lowercased(), url: url)
            }
        }
        throw PluginToolchainError.noSupportedToolchain
    }
}
