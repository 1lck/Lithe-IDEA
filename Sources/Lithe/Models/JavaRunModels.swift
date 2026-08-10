import Foundation

/// Language-neutral options owned by the run subsystem.
///
/// Java and Maven settings remain available as provider capabilities, but the
/// common argument/environment fields are usable by every process provider.
struct RunOptions: Codable, Hashable, Sendable {
    struct JavaCapability: Codable, Hashable, Sendable {
        var homePath = ""
        var vmArguments = ""
        var activeMavenProfiles: Set<String> = []
    }

    var workingDirectoryPath = ""
    var arguments = ""
    var environment: [String: String] = [:]
    var java = JavaCapability()

    init(
        javaHomePath: String = "",
        workingDirectoryPath: String = "",
        vmArguments: String = "",
        programArguments: String = "",
        activeProfiles: Set<String> = [],
        environment: [String: String] = [:]
    ) {
        self.workingDirectoryPath = workingDirectoryPath
        arguments = programArguments
        self.environment = environment
        java = JavaCapability(
            homePath: javaHomePath,
            vmArguments: vmArguments,
            activeMavenProfiles: activeProfiles
        )
    }

    // Compatibility accessors keep Java debug and the one-release preference
    // migration readable while new code uses the generic fields above.
    var javaHomePath: String {
        get { java.homePath }
        set { java.homePath = newValue }
    }

    var vmArguments: String {
        get { java.vmArguments }
        set { java.vmArguments = newValue }
    }

    var programArguments: String {
        get { arguments }
        set { arguments = newValue }
    }

    var activeProfiles: Set<String> {
        get { java.activeMavenProfiles }
        set { java.activeMavenProfiles = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectoryPath
        case arguments
        case environment
        case java
        // Legacy UserDefaults keys used by JavaRunOptions.
        case javaHomePath
        case vmArguments
        case programArguments
        case activeProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath) ?? ""
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
            ?? container.decodeIfPresent(String.self, forKey: .programArguments)
            ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        java = try container.decodeIfPresent(JavaCapability.self, forKey: .java) ?? JavaCapability(
            homePath: try container.decodeIfPresent(String.self, forKey: .javaHomePath) ?? "",
            vmArguments: try container.decodeIfPresent(String.self, forKey: .vmArguments) ?? "",
            activeMavenProfiles: try container.decodeIfPresent(Set<String>.self, forKey: .activeProfiles) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(java, forKey: .java)
    }
}

/// Source compatibility for extensions and persisted data written before the
/// generic run-core migration. New run code should use `RunOptions`.
typealias JavaRunOptions = RunOptions

struct RunSession: Identifiable, Hashable, Sendable {
    let id: String
    let configurationID: String
    let title: String
    var output: String
    var isRunning: Bool
    var exitCode: Int32?
}

struct RunPortConflict: Identifiable, Hashable, Sendable {
    let port: Int
    let configurationNames: [String]

    var id: String { String(port) }

    var title: String {
        "Port (port) is used by " + configurationNames.joined(separator: ", ")
    }
}

struct RunConfigurationCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let workingDirectory = Self(rawValue: 1 << 0)
    static let arguments = Self(rawValue: 1 << 1)
    static let environment = Self(rawValue: 1 << 2)
    static let javaRuntime = Self(rawValue: 1 << 3)
    static let javaVMArguments = Self(rawValue: 1 << 4)
    static let mavenProfiles = Self(rawValue: 1 << 5)
    static let jdwpDebug = Self(rawValue: 1 << 6)

    static let process: Self = [.workingDirectory, .arguments, .environment]
}

enum RunConfigurationKind: Hashable, Identifiable, Sendable {
    case currentFile
    case springBoot
    case javaMain
    case mavenModule
    /// Any provider this build has no first-class handling for. Carrying the
    /// raw provider keeps unknown ecosystems visible and runnable instead of
    /// silently dropping them at the decode boundary.
    case process(provider: String)

    init?(rawValue: String) {
        switch rawValue {
        case "currentFile": self = .currentFile
        case "springBoot": self = .springBoot
        case "javaMain": self = .javaMain
        case "mavenModule": self = .mavenModule
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .currentFile: "currentFile"
        case .springBoot: "springBoot"
        case .javaMain: "javaMain"
        case .mavenModule: "mavenModule"
        case .process(let provider): provider
        }
    }

    var providerID: String {
        switch self {
        case .currentFile, .javaMain: "java"
        case .springBoot, .mavenModule: "maven"
        case .process(let provider): provider.split(separator: ".").first.map(String.init) ?? provider
        }
    }

    /// True for the Maven-backed kinds that support JDWP debugging and Maven
    /// profiles. Callers should branch on this rather than enumerating cases.
    var isMavenBacked: Bool {
        self == .springBoot || self == .mavenModule
    }

    var capabilities: RunConfigurationCapabilities {
        switch self {
        case .currentFile, .javaMain:
            return [.workingDirectory, .arguments, .environment, .javaRuntime, .javaVMArguments, .jdwpDebug]
        case .springBoot, .mavenModule:
            return [.workingDirectory, .arguments, .environment, .javaRuntime, .javaVMArguments, .mavenProfiles, .jdwpDebug]
        case .process:
            return .process
        }
    }

    var title: String {
        switch self {
        case .currentFile: "Current File"
        case .springBoot: "Spring Boot"
        case .javaMain: "Java Application"
        case .mavenModule: "Maven Module"
        case .process(let provider): Self.displayTitle(for: provider)
        }
    }

    var systemImage: String {
        switch self {
        case .currentFile: "doc.text"
        case .springBoot: "leaf"
        case .javaMain: "cup.and.heat.waves"
        case .mavenModule: "shippingbox"
        case .process(let provider): Self.symbol(for: provider)
        }
    }

    /// Providers are `namespace.name`. Falling back to a title-cased namespace
    /// means an ecosystem this build has never heard of still reads as a label
    /// rather than as a raw identifier.
    private static func displayTitle(for provider: String) -> String {
        let namespace = provider.split(separator: ".").first.map(String.init) ?? provider
        switch namespace {
        case "npm": return "Node"
        case "compose": return "Docker Compose"
        case "python": return "Python"
        case "go": return "Go"
        case "cargo": return "Rust"
        case "make": return "Make"
        case "just": return "Just"
        case "procfile": return "Procfile"
        default: return namespace.capitalized
        }
    }

    private static func symbol(for provider: String) -> String {
        switch provider.split(separator: ".").first.map(String.init) {
        case "compose": return "square.stack.3d.up"
        case "npm", "python", "go", "cargo": return "chevron.left.forwardslash.chevron.right"
        default: return "terminal"
        }
    }
}

enum RunConfigurationExecution: String, CaseIterable, Hashable, Sendable {
    case application
    case service
    case task
    case group

    static let displayOrder: [Self] = [.service, .application, .task, .group]

    var sectionTitle: String {
        switch self {
        case .application: "Applications"
        case .service: "Services"
        case .task: "Tasks"
        case .group: "Groups"
        }
    }
}

struct RunConfiguration: Identifiable, Hashable, Sendable {
    static let currentFileID = "current-file"

    let id: String
    let name: String
    let kind: RunConfigurationKind
    let execution: RunConfigurationExecution
    let modulePath: String?
    let mainClass: String?

    var usesCurrentEditorFile: Bool { kind == .currentFile }

    init(
        id: String,
        name: String,
        kind: RunConfigurationKind,
        execution: RunConfigurationExecution? = nil,
        modulePath: String?,
        mainClass: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.execution = execution ?? Self.defaultExecution(for: kind)
        self.modulePath = modulePath
        self.mainClass = mainClass
    }

    var systemImage: String { kind.systemImage }

    /// Current File is a language-neutral entry. Java keeps its legacy JDK
    /// capability, while other Providers expose only the shared process
    /// fields in the configuration editor.
    func effectiveCapabilities(
        for currentFileURL: URL?,
        catalog: LanguageProviderCatalog = .standard
    ) -> RunConfigurationCapabilities {
        guard kind == .currentFile else { return kind.capabilities }
        guard let currentFileURL,
              let descriptor = catalog.provider(for: currentFileURL) else {
            // An unknown extension is still a language-neutral Current File
            // entry. Showing JDK/Maven controls here would make an unsupported
            // language look like a Java project and leak provider assumptions
            // into the shared editor.
            return .process
        }
        guard descriptor.id == "java" else {
            return .process
        }
        return kind.capabilities
    }

    static var currentFile: RunConfiguration {
        RunConfiguration(
            id: currentFileID,
            name: "Current File",
            kind: .currentFile,
            execution: .application,
            modulePath: nil,
            mainClass: nil
        )
    }

    private static func defaultExecution(
        for kind: RunConfigurationKind
    ) -> RunConfigurationExecution {
        switch kind {
        case .springBoot: .service
        case .currentFile, .javaMain, .process: .application
        case .mavenModule: .task
        }
    }
}

// Temporary source compatibility at the Java-debug boundary. These aliases do
// not own behavior; the canonical models above are language neutral.
typealias JavaRunSession = RunSession
typealias JavaRunPortConflict = RunPortConflict
typealias JavaRunConfigurationKind = RunConfigurationKind
typealias JavaRunConfiguration = RunConfiguration
