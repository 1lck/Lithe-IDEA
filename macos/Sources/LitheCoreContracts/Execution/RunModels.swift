import Foundation

package struct RunSession: Identifiable, Hashable, Sendable {
    package let id: String
    package let configurationID: String
    package let title: String
    package var output: String
    package var isRunning: Bool
    package var exitCode: Int32?

    package init(
        id: String,
        configurationID: String,
        title: String,
        output: String,
        isRunning: Bool,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.configurationID = configurationID
        self.title = title
        self.output = output
        self.isRunning = isRunning
        self.exitCode = exitCode
    }
}

package struct RunPortConflict: Identifiable, Hashable, Sendable {
    package let port: Int
    package let configurationNames: [String]

    package init(port: Int, configurationNames: [String]) {
        self.port = port
        self.configurationNames = configurationNames
    }

    package var id: String { String(port) }

    package var title: String {
        "Port \(port) is used by " + configurationNames.joined(separator: ", ")
    }
}

package struct RunConfigurationCapabilities: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let workingDirectory = Self(rawValue: 1 << 0)
    package static let arguments = Self(rawValue: 1 << 1)
    package static let environment = Self(rawValue: 1 << 2)
    package static let javaRuntime = Self(rawValue: 1 << 3)
    package static let javaVMArguments = Self(rawValue: 1 << 4)
    package static let mavenProfiles = Self(rawValue: 1 << 5)
    package static let jdwpDebug = Self(rawValue: 1 << 6)

    package static let process: Self = [.workingDirectory, .arguments, .environment]
}

/// A JVM framework launched by a Maven goal rather than by spawning a process.
///
/// These share Spring Boot's capabilities exactly -- the core assembles the goal
/// and the property names its arguments travel under -- so they are one case
/// carrying the framework rather than three parallel cases.
package enum MavenFrameworkKind: String, Hashable, Sendable, CaseIterable {
    case springBoot
    case quarkus
    case micronaut

    /// The core provider this framework is reported as.
    package var provider: String {
        switch self {
        case .springBoot: "spring-boot.maven"
        case .quarkus: "quarkus.maven"
        case .micronaut: "micronaut.maven"
        }
    }

    package var title: String {
        switch self {
        case .springBoot: "Spring Boot"
        case .quarkus: "Quarkus"
        case .micronaut: "Micronaut"
        }
    }

    /// Only Spring Boot's goal accepts a main class; Quarkus and Micronaut
    /// resolve it from the build, so naming one would be ignored.
    package var namesMainClass: Bool { self == .springBoot }
}

package enum RunConfigurationKind: Hashable, Identifiable, Sendable {
    case currentFile
    case javaMain
    case mavenModule
    /// A JVM framework whose service is started by a Maven goal.
    case mavenFramework(MavenFrameworkKind)
    /// Any provider this build has no first-class handling for. Carrying the
    /// raw provider keeps unknown ecosystems visible and runnable instead of
    /// silently dropping them at the decode boundary.
    case process(provider: String)

    package static let springBoot: Self = .mavenFramework(.springBoot)

    package init?(rawValue: String) {
        switch rawValue {
        case "currentFile": self = .currentFile
        case "springBoot": self = .springBoot
        case "javaMain": self = .javaMain
        case "mavenModule": self = .mavenModule
        case "quarkus": self = .mavenFramework(.quarkus)
        case "micronaut": self = .mavenFramework(.micronaut)
        default: return nil
        }
    }

    package var id: String {
        switch self {
        case .currentFile: "currentFile"
        case .javaMain: "javaMain"
        case .mavenModule: "mavenModule"
        case .mavenFramework(let framework): framework.rawValue
        case .process(let provider): provider
        }
    }

    package var providerID: String {
        switch self {
        case .currentFile, .javaMain: "java"
        case .mavenModule, .mavenFramework: "maven"
        case .process(let provider): provider.split(separator: ".").first.map(String.init) ?? provider
        }
    }

    /// The framework whose Maven goal starts this configuration, if any.
    package var mavenFramework: MavenFrameworkKind? {
        if case .mavenFramework(let framework) = self { return framework }
        return nil
    }

    /// True for the Maven-backed kinds that support JDWP debugging and Maven
    /// profiles. Callers should branch on this rather than enumerating cases.
    package var isMavenBacked: Bool {
        self == .mavenModule || mavenFramework != nil
    }

    package var capabilities: RunConfigurationCapabilities {
        switch self {
        case .currentFile, .javaMain:
            return [.workingDirectory, .arguments, .environment, .javaRuntime, .javaVMArguments, .jdwpDebug]
        case .mavenModule, .mavenFramework:
            return [.workingDirectory, .arguments, .environment, .javaRuntime, .javaVMArguments, .mavenProfiles, .jdwpDebug]
        case .process:
            return .process
        }
    }

    package var title: String {
        switch self {
        case .currentFile: "Current File"
        case .javaMain: "Java Application"
        case .mavenModule: "Maven Module"
        case .mavenFramework(let framework): framework.title
        case .process(let provider): Self.displayTitle(for: provider)
        }
    }

    package var systemImage: String {
        switch self {
        case .currentFile: "doc.text"
        case .javaMain: "cup.and.heat.waves"
        case .mavenModule: "shippingbox"
        // All three are long-running JVM services started the same way, so they
        // share one symbol rather than implying a difference that is not there.
        case .mavenFramework: "leaf"
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

package enum RunConfigurationExecution: String, CaseIterable, Hashable, Sendable {
    case application
    case service
    case task
    case group

    package static let displayOrder: [Self] = [.service, .application, .task, .group]

    package var sectionTitle: String {
        switch self {
        case .application: "Applications"
        case .service: "Services"
        case .task: "Tasks"
        case .group: "Groups"
        }
    }
}

package struct RunConfiguration: Identifiable, Hashable, Sendable {
    package static let currentFileID = "current-file"

    package let id: String
    package let name: String
    package let kind: RunConfigurationKind
    package let execution: RunConfigurationExecution
    package let modulePath: String?
    package let mainClass: String?

    package var usesCurrentEditorFile: Bool { kind == .currentFile }

    package init(
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

    package var systemImage: String { kind.systemImage }

    /// Current File is a language-neutral entry. Java keeps its legacy JDK
    /// capability, while other Providers expose only the shared process
    /// fields in the configuration editor.
    package func effectiveCapabilities(
        for currentFileURL: URL?,
        catalog: LanguageProviderCatalog = .compatibilityFallback
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

    package static var currentFile: RunConfiguration {
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
        case .mavenFramework: .service
        case .currentFile, .javaMain, .process: .application
        case .mavenModule: .task
        }
    }
}

// Temporary source compatibility at the Java-debug boundary. These aliases do
// not own behavior; the canonical models above are language neutral.
package typealias JavaRunSession = RunSession
package typealias JavaRunPortConflict = RunPortConflict
package typealias JavaRunConfigurationKind = RunConfigurationKind
package typealias JavaRunConfiguration = RunConfiguration
