import Foundation

struct JavaRunOptions: Codable, Hashable, Sendable {
    var javaHomePath = ""
    var workingDirectoryPath = ""
    var vmArguments = ""
    var programArguments = ""
    var activeProfiles: Set<String> = []
}

struct JavaRunSession: Identifiable, Hashable, Sendable {
    let id: String
    let configurationID: String
    let title: String
    var output: String
    var isRunning: Bool
    var exitCode: Int32?
}

struct JavaRunPortConflict: Identifiable, Hashable, Sendable {
    let port: Int
    let configurationNames: [String]

    var id: String { String(port) }

    var title: String {
        "Port (port) is used by " + configurationNames.joined(separator: ", ")
    }
}

enum JavaRunConfigurationKind: Hashable, Identifiable, Sendable {
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

    /// True for the Maven-backed kinds that support JDWP debugging and Maven
    /// profiles. Callers should branch on this rather than enumerating cases.
    var isMavenBacked: Bool {
        self == .springBoot || self == .mavenModule
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

struct JavaRunConfiguration: Identifiable, Hashable, Sendable {
    static let currentFileID = "current-file"

    let id: String
    let name: String
    let kind: JavaRunConfigurationKind
    let execution: RunConfigurationExecution
    let modulePath: String?
    let mainClass: String?

    init(
        id: String,
        name: String,
        kind: JavaRunConfigurationKind,
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

    static var currentFile: JavaRunConfiguration {
        JavaRunConfiguration(
            id: currentFileID,
            name: "Current File",
            kind: .currentFile,
            execution: .application,
            modulePath: nil,
            mainClass: nil
        )
    }

    private static func defaultExecution(
        for kind: JavaRunConfigurationKind
    ) -> RunConfigurationExecution {
        switch kind {
        case .springBoot: .service
        case .currentFile, .javaMain, .process: .application
        case .mavenModule: .task
        }
    }
}
