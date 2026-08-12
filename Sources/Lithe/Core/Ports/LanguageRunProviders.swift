import Foundation

struct LanguageRunContext: Equatable, Sendable {
    let workspaceURL: URL
    let fileURL: URL

    init(workspaceURL: URL, fileURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileURL = fileURL.standardizedFileURL
    }

    var relativeFilePath: String? {
        let root = workspaceURL.path
        let file = fileURL.path
        guard file == root || file.hasPrefix(root + "/") else { return nil }
        guard file != root else { return "" }
        return String(file.dropFirst(root.count + 1))
    }
}

enum RunArgumentParser {
    static func parse(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in input {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
                continue
            }
            if character.isWhitespace && quote == nil {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum LanguageRunPlanError: LocalizedError, Equatable, Sendable {
    case noProvider(fileExtension: String)
    case fileOutsideWorkspace(URL)
    case unsupportedCurrentFile(String)

    var errorDescription: String? {
        switch self {
        case .noProvider(let fileExtension):
            return "No language run provider handles .\(fileExtension) files."
        case .fileOutsideWorkspace(let url):
            return "The current file is outside the workspace: \(url.path)"
        case .unsupportedCurrentFile(let provider):
            return "\(provider) does not support running the current file directly. Use a project run configuration."
        }
    }
}

/// Language-specific translation for the language-neutral Current File entry.
/// The provider creates only a launch plan; executable lookup and process
/// lifecycle remain in the shared RunService and injected platform adapters.
protocol LanguageRunProvider: Sendable {
    var descriptor: LanguageProviderDescriptor { get }
    func launchPlan(
        context: LanguageRunContext,
        options: RunOptions
    ) throws -> SharedLaunchPlan
}

struct StandardLanguageRunProvider: LanguageRunProvider {
    let descriptor: LanguageProviderDescriptor

    func launchPlan(
        context: LanguageRunContext,
        options: RunOptions
    ) throws -> SharedLaunchPlan {
        guard let relative = context.relativeFilePath else {
            throw LanguageRunPlanError.fileOutsideWorkspace(context.fileURL)
        }
        guard !relative.isEmpty else {
            throw LanguageRunPlanError.unsupportedCurrentFile(descriptor.displayName)
        }

        switch descriptor.id {
        case "go":
            return SharedLaunchPlan(
                executable: .toolchain("project-go"),
                arguments: ["run", relative] + RunArgumentParser.parse(options.arguments),
                workingDirectory: ".",
                environment: options.environment
            )
        case "python":
            return SharedLaunchPlan(
                executable: .toolchain("project-python"),
                arguments: [relative] + RunArgumentParser.parse(options.arguments),
                workingDirectory: ".",
                environment: options.environment
            )
        case "node":
            let extensionName = context.fileURL.pathExtension.lowercased()
            if extensionName == "ts" || extensionName == "tsx" {
                return SharedLaunchPlan(
                    executable: .toolchain("project-tsx"),
                    arguments: [relative] + RunArgumentParser.parse(options.arguments),
                    workingDirectory: ".",
                    environment: options.environment
                )
            }
            return SharedLaunchPlan(
                executable: .toolchain("project-node"),
                arguments: [relative] + RunArgumentParser.parse(options.arguments),
                workingDirectory: ".",
                environment: options.environment
            )
        case "rust":
            throw LanguageRunPlanError.unsupportedCurrentFile(descriptor.displayName)
        default:
            throw LanguageRunPlanError.unsupportedCurrentFile(descriptor.displayName)
        }
    }
}

struct LanguageRunProviderRegistry: Sendable {
    private let providersByID: [String: any LanguageRunProvider]
    private let descriptors: [LanguageProviderDescriptor]

    init(providers: [any LanguageRunProvider]) {
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
        descriptors = providers.map(\.descriptor)
    }

    static func standard(catalog: LanguageProviderCatalog = .standard) -> Self {
        Self(providers: catalog.descriptors
            .filter { $0.capabilities.contains(.run) && $0.id != "java" }
            .map(StandardLanguageRunProvider.init))
    }

    func provider(for fileURL: URL) -> (any LanguageRunProvider)? {
        guard let descriptor = descriptors.first(where: { $0.handles(fileURL: fileURL) }) else { return nil }
        return providersByID[descriptor.id]
    }

    func provider(id: String) -> (any LanguageRunProvider)? {
        providersByID[id]
    }

    func launchPlan(
        for fileURL: URL,
        workspaceURL: URL,
        options: RunOptions = RunOptions()
    ) throws -> SharedLaunchPlan {
        guard let provider = provider(for: fileURL) else {
            throw LanguageRunPlanError.noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        return try provider.launchPlan(
            context: LanguageRunContext(workspaceURL: workspaceURL, fileURL: fileURL),
            options: options
        )
    }
}
