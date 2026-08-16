import Foundation
import LitheModuleAPI

public extension PluginHostServiceID {
    static let languageExecution = PluginHostServiceID("dev.lithe.host.language-execution.v1")
}

public enum LanguageExecutionLifecycleState: String, Sendable {
    case starting
    case running
    case stopping
    case finished
    case failed
}

public struct LanguageExecutionLifecycleEvent: Sendable {
    public let operationID: String?
    public let state: LanguageExecutionLifecycleState
    public let exitCode: Int32?
    public let message: String?

    public init(
        operationID: String?,
        state: LanguageExecutionLifecycleState,
        exitCode: Int32? = nil,
        message: String? = nil
    ) {
        self.operationID = operationID
        self.state = state
        self.exitCode = exitCode
        self.message = message
    }
}

public struct LanguageExecutionProcessRequest: Sendable {
    public let operationID: String?
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?

    public init(
        operationID: String? = nil,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.operationID = operationID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

@MainActor
public protocol LanguageExecutionSession: AnyObject {
    var isRunning: Bool { get }
    var onOutput: (@Sendable (String) -> Void)? { get set }
    var onTermination: (@Sendable (Int32) -> Void)? { get set }
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)? { get set }

    func start(_ request: LanguageExecutionProcessRequest) throws
    func stop()
    func stopAndWait() async -> Bool
}

public extension LanguageExecutionSession {
    func stopAndWait() async -> Bool {
        stop()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !isRunning
    }
}

@MainActor
public protocol LanguageExecutionHostProviding: AnyObject {
    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession
}

public struct LanguageServerExtensionConfiguration: Equatable, Sendable {
    public let languageID: String
    public let displayName: String
    public let executableNames: [String]
    public let arguments: [String]
    public let validationArguments: [String]
    public let environment: [String: String]
    public let languageIdentifier: String

    public init(
        languageID: String,
        displayName: String,
        executableNames: [String],
        arguments: [String] = [],
        validationArguments: [String] = [],
        environment: [String: String] = [:],
        languageIdentifier: String
    ) {
        self.languageID = languageID
        self.displayName = displayName
        self.executableNames = executableNames
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.environment = environment
        self.languageIdentifier = languageIdentifier
    }
}

@MainActor
public protocol LanguageServerExtensionProviding: AnyObject {
    var configuration: LanguageServerExtensionConfiguration { get }
    var lifecycle: any LanguageServerExtensionLifecycle { get }
}

@MainActor
public protocol LanguageServerExtensionLifecycle: AnyObject {
    var isRunning: Bool { get }
    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    )
    func stop()
    func waitUntilStopped() async
}

public extension LanguageServerExtensionLifecycle {
    func waitUntilStopped() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}

public struct LanguageRunExtensionRequest: Equatable, Sendable {
    public let relativeFilePath: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        relativeFilePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.relativeFilePath = relativeFilePath
        self.arguments = arguments
        self.environment = environment
    }
}

public enum LanguageRunExtensionExecutable: Equatable, Sendable {
    case toolchain(String)
    case command(String)
}

public struct LanguageRunExtensionPlan: Equatable, Sendable {
    public let executable: LanguageRunExtensionExecutable
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]

    public init(
        executable: LanguageRunExtensionExecutable,
        arguments: [String],
        workingDirectory: String = ".",
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

@MainActor
public protocol LanguageRunExtensionProviding: AnyObject {
    var languageID: String { get }
    func makeExecutionSession() -> any LanguageExecutionSession
    func launchPlan(for request: LanguageRunExtensionRequest) throws -> LanguageRunExtensionPlan
}

public enum LanguageTestExtensionItemKind: String, Equatable, Sendable {
    case workspace
    case file
    case testCase
}

public struct LanguageTestExtensionItem: Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: LanguageTestExtensionItemKind
    public let relativeFilePath: String?

    public init(
        id: String,
        label: String,
        kind: LanguageTestExtensionItemKind,
        relativeFilePath: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.relativeFilePath = relativeFilePath
    }
}

public struct LanguageTestExtensionDiscoveryRequest: Equatable, Sendable {
    public let relativeProjectFilePaths: [String]

    public init(relativeProjectFilePaths: [String]) {
        self.relativeProjectFilePaths = relativeProjectFilePaths
    }
}

public enum LanguageTestExtensionScope: Equatable, Sendable {
    case workspace
    case file(relativePath: String)
    case testCase(identifier: String, relativeFilePath: String?)
}

public struct LanguageTestExtensionRequest: Equatable, Sendable {
    public let scope: LanguageTestExtensionScope
    public let relativeProjectFilePaths: [String]

    public init(
        scope: LanguageTestExtensionScope,
        relativeProjectFilePaths: [String]
    ) {
        self.scope = scope
        self.relativeProjectFilePaths = relativeProjectFilePaths
    }
}

public struct LanguageTestExtensionPlan: Equatable, Sendable {
    public let label: String
    public let frameworkID: String?
    public let launchPlan: LanguageRunExtensionPlan

    public init(
        label: String,
        frameworkID: String? = nil,
        launchPlan: LanguageRunExtensionPlan
    ) {
        self.label = label
        self.frameworkID = frameworkID
        self.launchPlan = launchPlan
    }
}

@MainActor
public protocol LanguageTestExtensionProviding: AnyObject {
    var languageID: String { get }
    func makeTestExecutionSession() -> any LanguageExecutionSession
    func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem]
    func testPlan(
        for request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan
}

public enum LanguageExtensionHostError: Error, Equatable, LocalizedError, Sendable {
    case missingExecutionHost(languageID: String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutionHost(let languageID):
            "The host cannot provide an execution session for \(languageID)."
        }
    }
}

public enum LanguageExtensionRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case invalidLanguageServerProvider(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLanguageServerProvider(let displayName):
            "\(displayName) returned an invalid language-server provider."
        }
    }
}

public enum LanguageRunExtensionError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelativePath

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "The selected file must be inside the current workspace."
        }
    }
}

public enum LanguageTestExtensionError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelativePath
    case invalidTestIdentifier
    case unsupportedProject(languageID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "A test path must stay inside the current workspace."
        case .invalidTestIdentifier:
            "The selected test identifier is invalid."
        case .unsupportedProject(let languageID):
            "The workspace is not a supported \(languageID) test project."
        }
    }
}
