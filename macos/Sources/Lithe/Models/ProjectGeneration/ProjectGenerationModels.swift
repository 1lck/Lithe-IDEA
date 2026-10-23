import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// One installed plugin as the New Project catalog reads it.
struct ProjectGeneratorPluginSource: Equatable, Sendable {
    let pluginID: PluginID
    /// Normalized manifest from `plugins.declarative.validate`.
    let manifest: Data
    /// Installed package directory; templates are read from it, never written.
    let packageURL: URL
    let isEnabled: Bool
}

/// A generator of one plugin, addressed in every `project.*` command.
struct ProjectGeneratorTarget: Equatable, Sendable {
    let pluginID: PluginID
    let generatorID: String
    let manifest: Data
    let packageURL: URL
}

/// Where a catalog entry is listed: IDEA's "New Project" and "Generators".
enum ProjectGeneratorSection: String, Decodable, Sendable {
    case project
    case generator
}

/// A generator field as Rust Core normalized it.
struct ProjectGeneratorField: Decodable, Equatable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable {
        case text, `enum`, boolean, multiSelect, runtime
    }

    enum Presentation: String, Decodable, Sendable {
        case segmented, menu
    }

    struct Option: Decodable, Equatable, Sendable, Hashable {
        let value: String
        let title: String
        let group: String?
    }

    let id: String
    let kind: Kind
    let title: String
    let description: String?
    let advanced: Bool
    let options: [Option]
    let presentation: Presentation?
    let placeholder: String?
    let optional: Bool
    let runtime: String?
    let minimumVersion: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind = "type", title, description, advanced, options, presentation, placeholder, optional
        case runtime, minimumVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        advanced = try values.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
        options = try values.decodeIfPresent([Option].self, forKey: .options) ?? []
        presentation = try values.decodeIfPresent(Presentation.self, forKey: .presentation)
        placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder)
        optional = try values.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        runtime = try values.decodeIfPresent(String.self, forKey: .runtime)
        minimumVersion = try values.decodeIfPresent(String.self, forKey: .minimumVersion)
    }
}

/// A plugin that provides a requirement of a generator.
struct ProjectRequirementProvider: Decodable, Equatable, Sendable {
    let pluginID: String
    let pluginName: String
    let enabled: Bool
}

/// A language or build system the created project needs.
struct ProjectGeneratorRequirement: Decodable, Equatable, Sendable {
    enum Subject: Equatable, Sendable {
        case language(String)
        case buildSystem(String)
    }

    let subject: Subject
    let providers: [ProjectRequirementProvider]

    private enum CodingKeys: String, CodingKey {
        case languageID, buildSystemID, providers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let language = try values.decodeIfPresent(String.self, forKey: .languageID) {
            subject = .language(language)
        } else {
            subject = .buildSystem(try values.decode(String.self, forKey: .buildSystemID))
        }
        providers = try values.decode([ProjectRequirementProvider].self, forKey: .providers)
    }

    var subjectID: String {
        switch subject {
        case .language(let id), .buildSystem(let id): id
        }
    }
}

/// One entry of `project.generatorCatalog`.
struct ProjectGeneratorEntry: Decodable, Equatable, Sendable, Identifiable {
    struct Generator: Decodable, Equatable, Sendable {
        let id: String
        let displayName: String
        let description: String?
        let section: ProjectGeneratorSection
        let icon: PluginUIIcon?
        let fields: [ProjectGeneratorField]

        private enum CodingKeys: String, CodingKey {
            case id, displayName, description, section, icon, fields
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            displayName = try values.decode(String.self, forKey: .displayName)
            description = try values.decodeIfPresent(String.self, forKey: .description)
            section = try values.decode(ProjectGeneratorSection.self, forKey: .section)
            icon = try values.decodeIfPresent(PluginUIIcon.self, forKey: .icon)
            fields = try values.decodeIfPresent([ProjectGeneratorField].self, forKey: .fields) ?? []
        }
    }

    let pluginID: String
    let pluginName: String
    let pluginEnabled: Bool
    let generator: Generator
    let requirements: [ProjectGeneratorRequirement]
    let usesNetwork: Bool

    var id: String { "\(pluginID)/\(generator.id)" }
    var iconID: String { DeclarativeProjectGenerator.iconID(pluginID: pluginID, generatorID: generator.id) }
}

struct ProjectGeneratorCatalog: Decodable, Equatable, Sendable {
    struct Issue: Decodable, Equatable, Sendable {
        let pluginID: String?
        let error: CoreRejection
    }

    let generators: [ProjectGeneratorEntry]
    let issues: [Issue]
}

/// `{code, message, field?}` of a rejected `project.*` command.
struct CoreRejection: Decodable, Equatable, Sendable, Error {
    let code: String
    let message: String
    let field: String?
}

/// Why Rust Core does not accept a value. Hosts localize by code.
enum ProjectFieldProblem: String, Decodable, Equatable, Sendable {
    case required, tooLong, invalidFormat, unsupportedValue, runtimeTooOld
}

/// A selected runtime installation of a runtime field.
struct ProjectRuntimeSelection: Encodable, Equatable, Sendable {
    let home: String
    let version: String
}

/// What the user entered, sent to `project.generatorForm` and
/// `project.generationPlan`.
struct ProjectGeneratorFormInput: Encodable, Equatable, Sendable {
    var projectName: String
    var values: [String: ToolingJSONValue] = [:]
    /// Text fields the user typed in; the others follow their defaults.
    var edited: Set<String> = []
    var runtimes: [String: ProjectRuntimeSelection] = [:]

    private enum CodingKeys: String, CodingKey {
        case projectName, values, edited, runtimes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(values, forKey: .values)
        try container.encode(edited.sorted(), forKey: .edited)
        try container.encode(runtimes, forKey: .runtimes)
    }
}

/// `project.generatorForm`.
struct ProjectGeneratorFormState: Decodable, Equatable, Sendable {
    struct NameState: Decodable, Equatable, Sendable {
        let problem: ProjectFieldProblem?
    }

    struct FieldState: Decodable, Equatable, Sendable {
        let id: String
        let visible: Bool
        let value: ToolingJSONValue
        let problem: ProjectFieldProblem?
    }

    let projectName: NameState
    let fields: [FieldState]
    let activeRequirements: [Int]
    let valid: Bool

    func field(_ id: String) -> FieldState? { fields.first { $0.id == id } }
}

/// `project.generationPlan`: the steps the host runs in order.
struct ProjectGenerationPlan: Decodable, Equatable, Sendable {
    struct File: Decodable, Equatable, Sendable {
        let path: String
        let contents: String
        let executable: Bool
    }

    enum Step: Decodable, Equatable, Sendable {
        case writeFiles([File])
        case command(Command)
        case archive(url: URL, host: String)

        private enum CodingKeys: String, CodingKey {
            case kind, files, url, host
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(String.self, forKey: .kind) {
            case "writeFiles":
                self = .writeFiles(try values.decode([File].self, forKey: .files))
            case "command":
                self = .command(try Command(from: decoder))
            case "archive":
                guard let url = URL(string: try values.decode(String.self, forKey: .url)) else {
                    throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "Invalid URL")
                }
                self = .archive(url: url, host: try values.decode(String.self, forKey: .host))
            case let kind:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: values, debugDescription: "Unknown plan step \(kind)"
                )
            }
        }
    }

    struct Command: Decodable, Equatable, Sendable {
        let command: String
        let arguments: [String]
        let environment: [String: String]
        /// The tool writes the project into this subdirectory; its contents
        /// become the project root.
        let collect: String?
        let mayUseNetwork: Bool
        let timeoutSeconds: Int
    }

    struct Runtime: Decodable, Equatable, Sendable {
        let field: String
        let runtime: String
        let home: String
        let version: String
    }

    let projectName: String
    let steps: [Step]
    let openFiles: [String]
    let runtimes: [Runtime]
    let usesNetwork: Bool
}
