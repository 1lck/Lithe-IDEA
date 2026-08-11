import Foundation

struct LanguageToolingCapability: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let run = Self(rawValue: 1 << 0)
    static let languageServer = Self(rawValue: 1 << 1)
    static let debugAdapter = Self(rawValue: 1 << 2)
    static let formatting = Self(rawValue: 1 << 3)
    static let testing = Self(rawValue: 1 << 4)

    static func named(_ name: String) -> Self? {
        switch name {
        case "run": .run
        case "languageServer": .languageServer
        case "debugAdapter": .debugAdapter
        case "formatting": .formatting
        case "testing": .testing
        default: nil
        }
    }

    static func names(_ names: [String]) -> Self {
        names.reduce(into: Self()) { capabilities, name in
            if let capability = Self.named(name) {
                capabilities.insert(capability)
            }
        }
    }
}

struct LanguageServerFeatureSet: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let definition = Self(rawValue: 1 << 0)
    static let references = Self(rawValue: 1 << 1)
    static let implementation = Self(rawValue: 1 << 2)
    static let hover = Self(rawValue: 1 << 3)
    static let completion = Self(rawValue: 1 << 4)
    static let rename = Self(rawValue: 1 << 5)
    static let formatting = Self(rawValue: 1 << 6)
    static let codeActions = Self(rawValue: 1 << 7)
    static let completionResolve = Self(rawValue: 1 << 8)
    static let codeActionResolve = Self(rawValue: 1 << 9)
    static let executeCommand = Self(rawValue: 1 << 10)

    static let standardEditing: Self = [
        .definition, .references, .implementation, .hover, .completion,
        .rename, .formatting, .codeActions, .completionResolve,
        .codeActionResolve, .executeCommand
    ]
}

enum ToolingActivationPolicy: String, Codable, Hashable, Sendable {
    case onDemand
    case always
}

struct LanguageServerLaunchDescriptor: Hashable, Sendable {
    let executableNames: [String]
    let arguments: [String]
    let environment: [String: String]
    let initializationOptions: ToolingJSONValue?

    init(
        executableNames: [String],
        arguments: [String] = [],
        environment: [String: String] = [:],
        initializationOptions: ToolingJSONValue? = nil
    ) {
        self.executableNames = executableNames
        self.arguments = arguments
        self.environment = environment
        self.initializationOptions = initializationOptions
    }
}

struct LanguageServerInstallationDescriptor: Hashable, Sendable {
    let homebrewFormula: String?
    let officialDownloadURL: URL?
}

struct LanguageProviderDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let fileExtensions: Set<String>
    let fileNames: Set<String>
    let fileNamePrefixes: Set<String>
    let capabilities: LanguageToolingCapability
    let activationPolicy: ToolingActivationPolicy
    let languageIdentifier: String?
    let languageIdentifiersByExtension: [String: String]
    let languageIdentifiersByFileName: [String: String]
    let languageServerLaunch: LanguageServerLaunchDescriptor?
    let languageServerInstallation: LanguageServerInstallationDescriptor?

    init(
        id: String,
        displayName: String,
        fileExtensions: Set<String>,
        fileNames: Set<String> = [],
        fileNamePrefixes: Set<String> = [],
        capabilities: LanguageToolingCapability,
        activationPolicy: ToolingActivationPolicy,
        languageIdentifier: String? = nil,
        languageIdentifiersByExtension: [String: String] = [:],
        languageIdentifiersByFileName: [String: String] = [:],
        languageServerLaunch: LanguageServerLaunchDescriptor? = nil,
        languageServerInstallation: LanguageServerInstallationDescriptor? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = Set(fileExtensions.map { $0.lowercased() })
        self.fileNames = Set(fileNames.map { $0.lowercased() })
        self.fileNamePrefixes = Set(fileNamePrefixes.map { $0.lowercased() })
        self.capabilities = capabilities
        self.activationPolicy = activationPolicy
        self.languageIdentifier = languageIdentifier
        self.languageIdentifiersByExtension = Dictionary(
            uniqueKeysWithValues: languageIdentifiersByExtension.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.languageIdentifiersByFileName = Dictionary(
            uniqueKeysWithValues: languageIdentifiersByFileName.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.languageServerLaunch = languageServerLaunch
        self.languageServerInstallation = languageServerInstallation
    }

    func handles(fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent.lowercased()
        return fileExtensions.contains(fileURL.pathExtension.lowercased())
            || fileNames.contains(fileName)
            || fileNamePrefixes.contains { fileName.hasPrefix($0) }
    }

    func languageIdentifier(for fileURL: URL) -> String {
        let extensionName = fileURL.pathExtension.lowercased()
        let fileName = fileURL.lastPathComponent.lowercased()
        return languageIdentifiersByFileName[fileName]
            ?? languageIdentifiersByExtension[extensionName]
            ?? languageIdentifier
            ?? id
    }
}

struct LanguageProviderCatalog: Sendable {
    let descriptors: [LanguageProviderDescriptor]

    /// Minimal fallback used only when the Rust core is not linked. The full
    /// market language catalog is registered by Rust's dedicated LSP config.
    static let compatibilityFallback = LanguageProviderCatalog(descriptors: [
        LanguageProviderDescriptor(
            id: "java", displayName: "Java", fileExtensions: ["java"],
            capabilities: [.run, .languageServer, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "go", displayName: "Go", fileExtensions: ["go"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "python", displayName: "Python", fileExtensions: ["py", "pyw"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "node", displayName: "Node.js", fileExtensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand,
            languageIdentifier: "javascript",
            languageIdentifiersByExtension: [
                "ts": "typescript",
                "tsx": "typescriptreact",
                "jsx": "javascriptreact"
            ]
        ),
        LanguageProviderDescriptor(
            id: "rust", displayName: "Rust", fileExtensions: ["rs"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        ),
    ])

    func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        descriptors.first { $0.handles(fileURL: fileURL) }
    }
}

struct LanguageServerPosition: Equatable, Sendable {
    let line: Int
    let utf16Column: Int
}

struct LanguageServerRange: Equatable, Sendable {
    let start: LanguageServerPosition
    let end: LanguageServerPosition
}

struct LanguageServerDiagnostic: Equatable, Sendable {
    let range: LanguageServerRange
    let severity: Int?
    let message: String
    let source: String?
    let code: String?
}

struct LanguageServerLocation: Equatable, Sendable {
    let url: URL
    let range: LanguageServerRange
    let isReadOnly: Bool
    let displayPath: String?

    init(
        url: URL,
        range: LanguageServerRange,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        self.url = url
        self.range = range
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
    }
}

struct LanguageServerHover: Equatable, Sendable {
    let contents: String
    let isMarkdown: Bool
    let range: LanguageServerRange?
}

struct LanguageServerCompletionItem: Identifiable, Equatable, Sendable {
    let label: String
    let detail: String?
    let documentation: String?
    let insertText: String
    let sortText: String?
    let filterText: String?
    let kind: Int?
    let textEdit: LanguageServerTextEdit?
    let additionalTextEdits: [LanguageServerTextEdit]
    let data: ToolingJSONValue?

    var id: String {
        [label, detail ?? "", insertText, sortText ?? ""].joined(separator: "\u{1F}")
    }
}

struct LanguageServerCommand: Equatable, Sendable {
    let title: String
    let command: String
    let arguments: [ToolingJSONValue]
}

enum LanguageServerLogLevel: String, Sendable {
    case info
    case warning
    case error
}

enum LanguageServerSessionState: Equatable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case failed(exitCode: Int32?, message: String?)
}

struct LanguageServerLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let providerID: String
    let level: LanguageServerLogLevel
    let message: String
    let detail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        providerID: String,
        level: LanguageServerLogLevel,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.providerID = providerID
        self.level = level
        self.message = message
        self.detail = detail
    }
}

struct LanguageServerTextEdit: Equatable, Sendable {
    let range: LanguageServerRange
    let newText: String
}

struct LanguageServerWorkspaceEdit: Equatable, Sendable {
    let changes: [URL: [LanguageServerTextEdit]]

    init(changes: [URL: [LanguageServerTextEdit]] = [:]) {
        self.changes = changes
    }
}

struct LanguageServerCodeAction: Identifiable, Equatable, Sendable {
    let title: String
    let kind: String?
    let isPreferred: Bool
    let edit: LanguageServerWorkspaceEdit?
    let command: LanguageServerCommand?
    let data: ToolingJSONValue?

    var id: String { [title, kind ?? ""].joined(separator: "\u{1F}") }
}

enum LanguageTestItemKind: String, Equatable, Sendable {
    case workspace
    case file
    case testCase
}

struct LanguageTestItem: Identifiable, Equatable, Sendable {
    let id: String
    let providerID: String
    let label: String
    let kind: LanguageTestItemKind
    let fileURL: URL?
}

enum LanguageTestScope: Equatable, Sendable {
    case workspace
    case file(URL)
    case testCase(identifier: String, fileURL: URL?)
}

struct LanguageTestContext: Equatable, Sendable {
    let workspaceURL: URL
    let projectFiles: [URL]

    init(workspaceURL: URL, projectFiles: [URL] = []) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.projectFiles = projectFiles.map(\.standardizedFileURL)
    }

    var projectFileNames: Set<String> {
        Set(projectFiles.map { $0.lastPathComponent.lowercased() })
    }
}

struct LanguageTestPlan: Sendable {
    let providerID: String
    let label: String
    let frameworkID: String?
    let launchPlan: SharedLaunchPlan

    init(
        providerID: String,
        label: String,
        frameworkID: String? = nil,
        launchPlan: SharedLaunchPlan
    ) {
        self.providerID = providerID
        self.label = label
        self.frameworkID = frameworkID
        self.launchPlan = launchPlan
    }
}

protocol LanguageTestProvider: Sendable {
    var descriptor: LanguageProviderDescriptor { get }
    func discoverTests(workspaceURL: URL, files: [URL]) -> [LanguageTestItem]
    func discoverTests(context: LanguageTestContext) -> [LanguageTestItem]
    func testPlan(scope: LanguageTestScope, context: LanguageTestContext) throws -> LanguageTestPlan
}

extension LanguageTestProvider {
    func discoverTests(context: LanguageTestContext) -> [LanguageTestItem] {
        discoverTests(workspaceURL: context.workspaceURL, files: context.projectFiles)
    }

    func testPlan(scope: LanguageTestScope, workspaceURL: URL) throws -> LanguageTestPlan {
        try testPlan(
            scope: scope,
            context: LanguageTestContext(workspaceURL: workspaceURL)
        )
    }
}

@MainActor
protocol LanguageServerSession: AnyObject {
    var isRunning: Bool { get }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)? { get set }
    var onLog: ((LanguageServerLogLevel, String, String?) -> Void)? { get set }
    var onStateChange: ((LanguageServerSessionState) -> Void)? { get set }
    var features: LanguageServerFeatureSet { get }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? { get set }
    func start(rootURL: URL) throws
    func synchronize(fileURL: URL, text: String, languageID: String) throws
    func closeDocument(_ fileURL: URL)
    func completions(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws
    func hover(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws
    func navigate(
        method: String,
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws
    func rename(
        fileURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws
    func format(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws
    func codeActions(
        fileURL: URL,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws
    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws
    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws
    func execute(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws
    func stop()
}

extension LanguageServerSession {
    var features: LanguageServerFeatureSet { [] }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? {
        get { nil }
        set {}
    }
    var onLog: ((LanguageServerLogLevel, String, String?) -> Void)? {
        get { nil }
        set {}
    }
    var onStateChange: ((LanguageServerSessionState) -> Void)? {
        get { nil }
        set {}
    }
    func closeDocument(_: URL) {}
}

@MainActor
protocol DebugAdapterSession: AnyObject {
    var isRunning: Bool { get }
    var state: DebugAdapterState { get }
    func start(rootURL: URL) throws
    func stop()
}

@MainActor
protocol DebugAdapterTransport: AnyObject {
    var isRunning: Bool { get }
    var onData: ((Data) -> Void)? { get set }
    var onErrorOutput: ((Data) -> Void)? { get set }
    var onTermination: ((Int) -> Void)? { get set }
    func start(rootURL: URL) throws
    func send(_ data: Data) throws
    func stop()
}

@MainActor
protocol DebugAdapterChildTransportProviding: AnyObject {
    func makeChildTransport() -> (any DebugAdapterTransport)?
}

extension DebugAdapterSession {
    var state: DebugAdapterState { isRunning ? .running : .idle }
}

enum ToolingJSONValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: ToolingJSONValue])
    case array([ToolingJSONValue])
    case null

    var foundationObject: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationObject)
        case .array(let value): value.map(\.foundationObject)
        case .null: NSNull()
        }
    }

    static func fromFoundation(_ value: Any) -> ToolingJSONValue? {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) {
                return .integer(number.intValue)
            }
            return .number(double)
        }
        if let values = value as? [Any] { return .array(values.compactMap(fromFoundation)) }
        if let object = value as? [String: Any] {
            return .object(object.compactMapValues(fromFoundation))
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ToolingJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ToolingJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum DebugAdapterState: String, Equatable, Sendable {
    case idle
    case initializing
    case ready
    case launching
    case running
    case paused
    case terminated
    case failed
}

enum DebugRequestKind: String, Equatable, Sendable {
    case launch
    case attach
}

struct DebugLaunchConfiguration: Equatable, Sendable {
    let name: String
    let request: DebugRequestKind
    let arguments: [String: ToolingJSONValue]
}

struct DebugSourceBreakpoint: Hashable, Sendable {
    let line: Int
    let column: Int?
    let condition: String?

    init(line: Int, column: Int? = nil, condition: String? = nil) {
        self.line = line
        self.column = column
        self.condition = condition
    }
}

struct DebugBreakpoint: Identifiable, Equatable, Sendable {
    let id: Int
    let verified: Bool
    let message: String?
    let sourceURL: URL?
    let line: Int?
    let column: Int?
}

struct DebugThread: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct DebugStackFrame: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let sourceURL: URL?
    let line: Int
    let column: Int
}

struct DebugScope: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let variablesReference: Int
    let expensive: Bool
}

struct DebugVariable: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let value: String
    let type: String?
    let evaluateName: String?
    let variablesReference: Int

    var isExpandable: Bool { variablesReference > 0 }
}

enum DebugAdapterEvent: Equatable, Sendable {
    case initialized
    case output(category: String?, output: String)
    case stopped(reason: String, threadID: Int?, description: String?)
    case continued(threadID: Int?)
    case terminated(exitCode: Int?)
    case breakpoint(DebugBreakpoint)
}

enum DebugExecutionCommand: String, Equatable, Sendable {
    case continueExecution = "continue"
    case pause
    case next
    case stepIn
    case stepOut
}

@MainActor
protocol DebugAdapterControllingSession: DebugAdapterSession {
    var onStateChange: ((DebugAdapterState) -> Void)? { get set }
    var onEvent: ((DebugAdapterEvent) -> Void)? { get set }
    func launch(_ configuration: DebugLaunchConfiguration) throws
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL)
    func execute(_ command: DebugExecutionCommand, threadID: Int?)
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void)
    func requestStackTrace(
        threadID: Int,
        completion: @escaping (Result<[DebugStackFrame], Error>) -> Void
    )
    func requestScopes(
        frameID: Int,
        completion: @escaping (Result<[DebugScope], Error>) -> Void
    )
    func requestVariables(
        reference: Int,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    )
    func evaluate(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    )
}

@MainActor
protocol LanguageProviderRuntime: AnyObject {
    var descriptor: LanguageProviderDescriptor { get }
    var supportsLanguageServerSession: Bool { get }
    var supportsDebugAdapterSession: Bool { get }
    var unavailableToolingMessage: String? { get }
    func makeLanguageServerSession() -> (any LanguageServerSession)?
    func makeDebugAdapterSession() -> (any DebugAdapterSession)?
    func makeDebugAdapterSession(rootURL: URL) -> (any DebugAdapterSession)?
}

@MainActor
protocol LanguageProviderRuntimeFactory: AnyObject {
    func makeRuntime(for descriptor: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)?
}

extension LanguageProviderRuntime {
    var supportsLanguageServerSession: Bool { false }
    var supportsDebugAdapterSession: Bool { false }
    var unavailableToolingMessage: String? { nil }
    func makeLanguageServerSession() -> (any LanguageServerSession)? { nil }
    func makeDebugAdapterSession(rootURL: URL) -> (any DebugAdapterSession)? {
        makeDebugAdapterSession()
    }
}
