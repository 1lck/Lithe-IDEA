import Foundation

struct LanguageToolingCapability: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let run = Self(rawValue: 1 << 0)
    static let languageServer = Self(rawValue: 1 << 1)
    static let debugAdapter = Self(rawValue: 1 << 2)
    static let formatting = Self(rawValue: 1 << 3)
    static let testing = Self(rawValue: 1 << 4)
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
    /// Descriptor-only. No runtime process is created until a file or command
    /// explicitly asks for this provider.
    case onDemand
    case always
}

struct LanguageProviderDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let fileExtensions: Set<String>
    let capabilities: LanguageToolingCapability
    let activationPolicy: ToolingActivationPolicy

    func handles(fileURL: URL) -> Bool {
        fileExtensions.contains(fileURL.pathExtension.lowercased())
    }

    func languageIdentifier(for fileURL: URL) -> String {
        switch (id, fileURL.pathExtension.lowercased()) {
        case ("node", "ts"): "typescript"
        case ("node", "tsx"): "typescriptreact"
        case ("node", "jsx"): "javascriptreact"
        case ("node", _): "javascript"
        default: id
        }
    }
}

/// The catalog is metadata only. Concrete LSP and DAP sessions are injected
/// by a platform/provider adapter when a capability is used.
struct LanguageProviderCatalog: Sendable {
    let descriptors: [LanguageProviderDescriptor]

    static let standard = LanguageProviderCatalog(descriptors: [
        LanguageProviderDescriptor(
            id: "java", displayName: "Java", fileExtensions: ["java"],
            // Java debugging still uses the legacy JDB integration. Keep it
            // out of the generic DAP capability until a real Java DAP runtime
            // is injected, so metadata cannot promise a session that does not
            // exist.
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
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "rust", displayName: "Rust", fileExtensions: ["rs"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        )
    ])

    func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        descriptors.first { $0.handles(fileURL: fileURL) }
    }
}

@MainActor
protocol LanguageServerSession: AnyObject {
    var isRunning: Bool { get }
    var isReady: Bool { get }
    func start(rootURL: URL) throws
    func stop()
}

@MainActor
protocol LanguageServerFeatureReportingSession: LanguageServerSession {
    var supportedFeatures: LanguageServerFeatureSet { get }
    var onSupportedFeaturesChange: ((LanguageServerFeatureSet) -> Void)? { get set }
}

extension LanguageServerSession {
    var isReady: Bool { isRunning }
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

/// Inputs available to a test provider when it selects a framework-specific
/// runner. The provider receives metadata only; reading files or starting a
/// process remains the responsibility of the injected platform services.
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
    /// Context-aware discovery is optional for existing Providers. Providers
    /// that need build-system markers can override this without forcing every
    /// language implementation to change its public contract at once.
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
protocol LanguageServerDocumentSession: LanguageServerSession {
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)? { get set }
    func synchronizeDocument(url: URL, languageIdentifier: String, text: String)
    func closeDocument(url: URL)
}

@MainActor
protocol LanguageServerNavigationSession: LanguageServerDocumentSession {
    func locations(
        method: String,
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    )
}

@MainActor
protocol LanguageServerCodeIntelligenceSession: LanguageServerNavigationSession {
    func hover(
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    )
    func completions(
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    )
}

@MainActor
protocol LanguageServerEditingSession: LanguageServerCodeIntelligenceSession {
    func rename(
        documentURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    )
    func formatting(
        documentURL: URL,
        options: [String: Any],
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    )
    func codeActions(
        documentURL: URL,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    )
    func execute(
        command: LanguageServerCommand,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    )
    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    )
}

@MainActor
protocol DebugAdapterSession: AnyObject {
    var isRunning: Bool { get }
    var state: DebugAdapterState { get }
    func start(rootURL: URL) throws
    func stop()
}

/// Byte transport used by the language-neutral DAP state machine. Adapters may
/// use a child process' stdio, a TCP socket, or another platform implementation
/// without changing protocol sequencing and inspection behavior.
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

/// Server-style adapters can ask the client to start a child DAP session (for
/// example a Node process, browser target, worker, or subprocess). The parent
/// transport supplies another connection to the same adapter server without
/// exposing platform sockets to the protocol state machine.
@MainActor
protocol DebugAdapterChildTransportProviding: AnyObject {
    func makeChildTransport() -> (any DebugAdapterTransport)?
}

extension DebugAdapterSession {
    var state: DebugAdapterState { isRunning ? .running : .idle }
}

enum ToolingJSONValue: Equatable, Sendable {
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
    /// Metadata-only indication that this provider exposes the shared editing
    /// LSP contract. It must not start or probe a process.
    var supportsEditingSession: Bool { get }
    /// Metadata-only indication that this runtime has a configured debug
    /// adapter factory. Executable discovery still happens lazily on launch.
    var supportsDebugAdapterSession: Bool { get }
    /// Optional actionable guidance when a lazy runtime cannot be created.
    /// This keeps installation details in the platform/provider adapter while
    /// allowing the shared manager to present a useful error.
    var unavailableToolingMessage: String? { get }
    var declaredLanguageServerFeatures: LanguageServerFeatureSet { get }
    func makeLanguageServerSession() -> (any LanguageServerSession)?
    func makeDebugAdapterSession() -> (any DebugAdapterSession)?
    func makeDebugAdapterSession(rootURL: URL) -> (any DebugAdapterSession)?
}

extension LanguageProviderRuntime {
    var supportsEditingSession: Bool { false }
    var supportsDebugAdapterSession: Bool { false }
    var unavailableToolingMessage: String? { nil }
    var declaredLanguageServerFeatures: LanguageServerFeatureSet { [] }
    func makeDebugAdapterSession(rootURL: URL) -> (any DebugAdapterSession)? {
        makeDebugAdapterSession()
    }
}
