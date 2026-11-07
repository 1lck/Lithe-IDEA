import Foundation

package struct RunSession: Identifiable, Hashable, Sendable {
    /// Stable for one execution; replacing the output slot creates a new identity.
    package let executionID: String
    package let id: String
    package let configurationID: String
    package let title: String
    package var output: String
    package var isRunning: Bool
    package var exitCode: Int32?

    package init(
        executionID: String = UUID().uuidString,
        id: String,
        configurationID: String,
        title: String,
        output: String,
        isRunning: Bool,
        exitCode: Int32? = nil
    ) {
        self.executionID = executionID
        self.id = id
        self.configurationID = configurationID
        self.title = title
        self.output = output
        self.isRunning = isRunning
        self.exitCode = exitCode
    }
}

/// Fields a run configuration exposes in the shared editor.
package struct RunConfigurationCapabilities: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let workingDirectory = Self(rawValue: 1 << 0)
    package static let arguments = Self(rawValue: 1 << 1)
    package static let environment = Self(rawValue: 1 << 2)

    package static let process: Self = [.workingDirectory, .arguments, .environment]
}

package enum RunConfigurationKind: Hashable, Identifiable, Sendable {
    case currentFile
    /// Any provider reported by Core or a plugin. Carrying the raw provider
    /// keeps every ecosystem visible and runnable instead of dropping it at
    /// the decode boundary.
    case process(provider: String)

    package init?(rawValue: String) {
        switch rawValue {
        case "currentFile": self = .currentFile
        default: return nil
        }
    }

    package var id: String {
        switch self {
        case .currentFile: "currentFile"
        case .process(let provider): provider
        }
    }

    /// The provider namespace; Current File belongs to no provider.
    package var providerID: String {
        switch self {
        case .currentFile: ""
        case .process(let provider): provider.split(separator: ".").first.map(String.init) ?? provider
        }
    }

    package var capabilities: RunConfigurationCapabilities {
        switch self {
        case .currentFile:
            return .process
        case .process(let provider):
            return provider == "build.provider" ? [] : .process
        }
    }

    package var title: String {
        switch self {
        case .currentFile: "Current File"
        case .process(let provider): Self.displayTitle(for: provider)
        }
    }

    package var systemImage: String {
        switch self {
        case .currentFile: "doc.text"
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
    package let debugAdapter: String?
    package let disabled: Bool
    package let buildProvider: BuildProviderRunReference?

    package var usesCurrentEditorFile: Bool { kind == .currentFile }

    /// Saved provider services may attach through their declared registry type.
    package var usesProviderConnectionDebug: Bool {
        buildProvider?.execution == .service
    }

    package init(
        id: String,
        name: String,
        kind: RunConfigurationKind,
        execution: RunConfigurationExecution? = nil,
        debugAdapter: String? = nil,
        disabled: Bool = false,
        buildProvider: BuildProviderRunReference? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.execution = execution ?? .application
        self.debugAdapter = debugAdapter
        self.disabled = disabled
        self.buildProvider = buildProvider
    }

    package var systemImage: String { kind.systemImage }

    package static var currentFile: RunConfiguration {
        RunConfiguration(
            id: currentFileID,
            name: "Current File",
            kind: .currentFile,
            execution: .application
        )
    }
}
