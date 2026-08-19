import Foundation

/// Identifies a concrete highlighter implementation that a file-format mapping can select.
enum SyntaxHighlightingAdapterID: String, Decodable, Equatable {
    case generic
    case json
    case yaml
}

/// Describes how one configuration-file format is recognized and highlighted.
struct SyntaxHighlightingFormatDefinition: Decodable, Equatable {
    let id: String
    let displayName: String
    let fileExtensions: [String]
    let fileNames: [String]
    let fileNamePrefixes: [String]
    let adapter: SyntaxHighlightingAdapterID

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileExtensions
        case fileNames
        case fileNamePrefixes
        case adapter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        fileExtensions = try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        fileNames = try container.decodeIfPresent([String].self, forKey: .fileNames) ?? []
        fileNamePrefixes = try container.decodeIfPresent([String].self, forKey: .fileNamePrefixes) ?? []
        adapter = try container.decode(SyntaxHighlightingAdapterID.self, forKey: .adapter)
    }
}

enum SyntaxHighlightingConfigurationError: Error, Equatable {
    case unsupportedVersion(Int)
    case emptyFormatID
    case duplicateFormatID(String)
    case missingFileMatcher(String)
    case duplicateFileExtension(String)
    case duplicateFileName(String)
    case duplicateFileNamePrefix(String)
    case missingBundledConfiguration
}

/// Loads and validates the single mapping file used to select syntax-highlighting adapters.
struct SyntaxHighlightingRegistry {
    private struct Configuration: Decodable {
        let version: Int
        let formats: [SyntaxHighlightingFormatDefinition]
    }

    static let bundled: SyntaxHighlightingRegistry = {
        do {
            guard let url = SyntaxHighlightingResources.configurationURL else {
                throw SyntaxHighlightingConfigurationError.missingBundledConfiguration
            }
            return try SyntaxHighlightingRegistry(data: Data(contentsOf: url))
        } catch {
            // A bad packaged mapping must not make the editor unusable; retain its generic highlighting.
            NSLog("Syntax highlighting configuration could not be loaded: %@", String(describing: error))
            return SyntaxHighlightingRegistry()
        }
    }()

    let formats: [SyntaxHighlightingFormatDefinition]

    private let formatByExtension: [String: SyntaxHighlightingFormatDefinition]
    private let formatByFileName: [String: SyntaxHighlightingFormatDefinition]
    private let formatsByFileNamePrefix: [(String, SyntaxHighlightingFormatDefinition)]

    private init() {
        formats = []
        formatByExtension = [:]
        formatByFileName = [:]
        formatsByFileNamePrefix = []
    }

    init(data: Data) throws {
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard configuration.version == 1 else {
            throw SyntaxHighlightingConfigurationError.unsupportedVersion(configuration.version)
        }

        var formatIDs = Set<String>()
        var extensions: [String: SyntaxHighlightingFormatDefinition] = [:]
        var fileNames: [String: SyntaxHighlightingFormatDefinition] = [:]
        var fileNamePrefixes: [String: SyntaxHighlightingFormatDefinition] = [:]

        for format in configuration.formats {
            let formatID = format.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !formatID.isEmpty else {
                throw SyntaxHighlightingConfigurationError.emptyFormatID
            }
            guard formatIDs.insert(formatID).inserted else {
                throw SyntaxHighlightingConfigurationError.duplicateFormatID(formatID)
            }
            guard !format.fileExtensions.isEmpty
                    || !format.fileNames.isEmpty
                    || !format.fileNamePrefixes.isEmpty else {
                throw SyntaxHighlightingConfigurationError.missingFileMatcher(formatID)
            }

            for value in format.fileExtensions {
                let normalized = Self.normalizeFileExtension(value)
                guard !normalized.isEmpty, extensions[normalized] == nil else {
                    throw SyntaxHighlightingConfigurationError.duplicateFileExtension(normalized)
                }
                extensions[normalized] = format
            }
            for value in format.fileNames {
                let normalized = Self.normalizeFileName(value)
                guard !normalized.isEmpty, fileNames[normalized] == nil else {
                    throw SyntaxHighlightingConfigurationError.duplicateFileName(normalized)
                }
                fileNames[normalized] = format
            }
            for value in format.fileNamePrefixes {
                let normalized = Self.normalizeFileName(value)
                guard !normalized.isEmpty, fileNamePrefixes[normalized] == nil else {
                    throw SyntaxHighlightingConfigurationError.duplicateFileNamePrefix(normalized)
                }
                fileNamePrefixes[normalized] = format
            }
        }

        formats = configuration.formats
        formatByExtension = extensions
        formatByFileName = fileNames
        // Longest-first ordering makes overlapping prefixes deterministic.
        formatsByFileNamePrefix = fileNamePrefixes.sorted {
            if $0.key.count == $1.key.count {
                return $0.key < $1.key
            }
            return $0.key.count > $1.key.count
        }
    }

    func format(
        fileName: String? = nil,
        fileExtension: String
    ) -> SyntaxHighlightingFormatDefinition? {
        if let fileName {
            let normalizedFileName = Self.normalizeFileName(fileName)
            if let exactMatch = formatByFileName[normalizedFileName] {
                return exactMatch
            }
            if let prefixMatch = formatsByFileNamePrefix.first(where: {
                normalizedFileName.hasPrefix($0.0)
            }) {
                return prefixMatch.1
            }
        }
        return formatByExtension[Self.normalizeFileExtension(fileExtension)]
    }

    func adapter(fileName: String? = nil, fileExtension: String) -> SyntaxHighlightingAdapterID {
        format(fileName: fileName, fileExtension: fileExtension)?.adapter ?? .generic
    }

    private static func normalizeFileExtension(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .drop(while: { $0 == "." })
            .description
    }

    private static func normalizeFileName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private enum SyntaxHighlightingResources {
    private static var resourceBundle: Bundle {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        let adjacentURL = Bundle.main.bundleURL
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        if let packagedURL, let bundle = Bundle(url: packagedURL) {
            return bundle
        }
        if let bundle = Bundle(url: adjacentURL) {
            return bundle
        }
        return Bundle.module
    }

    static var configurationURL: URL? {
        resourceBundle.resourceURL?
            .appendingPathComponent("SyntaxHighlighting", isDirectory: true)
            .appendingPathComponent("format-mappings.json", isDirectory: false)
    }
}
