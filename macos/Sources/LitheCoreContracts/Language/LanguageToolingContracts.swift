import Foundation
import LitheModuleAPI

package struct LanguageToolingCapability: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let run = Self(rawValue: 1 << 0)
    package static let languageServer = Self(rawValue: 1 << 1)
    package static let debugAdapter = Self(rawValue: 1 << 2)
    package static let formatting = Self(rawValue: 1 << 3)
    package static let testing = Self(rawValue: 1 << 4)

    package static func named(_ name: String) -> Self? {
        switch name {
        case "run": .run
        case "languageServer": .languageServer
        case "debugAdapter": .debugAdapter
        case "formatting": .formatting
        case "testing": .testing
        default: nil
        }
    }

    package static func names(_ names: [String]) -> Self {
        names.reduce(into: Self()) { capabilities, name in
            if let capability = Self.named(name) {
                capabilities.insert(capability)
            }
        }
    }
}

package struct LanguageServerFeatureSet: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let definition = Self(rawValue: 1 << 0)
    package static let references = Self(rawValue: 1 << 1)
    package static let implementation = Self(rawValue: 1 << 2)
    package static let hover = Self(rawValue: 1 << 3)
    package static let completion = Self(rawValue: 1 << 4)
    package static let rename = Self(rawValue: 1 << 5)
    package static let formatting = Self(rawValue: 1 << 6)
    package static let codeActions = Self(rawValue: 1 << 7)
    package static let completionResolve = Self(rawValue: 1 << 8)
    package static let codeActionResolve = Self(rawValue: 1 << 9)
    package static let executeCommand = Self(rawValue: 1 << 10)
    package static let semanticTokens = Self(rawValue: 1 << 11)
    package static let inlayHints = Self(rawValue: 1 << 12)

    package static let standardEditing: Self = [
        .definition, .references, .implementation, .hover, .completion,
        .rename, .formatting, .codeActions, .completionResolve,
        .codeActionResolve, .executeCommand
    ]
}

package enum ToolingActivationPolicy: String, Codable, Hashable, Sendable {
    case onDemand
    case always
}

package struct LanguageServerLaunchDescriptor: Hashable, Sendable {
    package let executableNames: [String]
    package let arguments: [String]
    package let validationArguments: [String]
    package let environment: [String: String]
    package let runtimeTools: [String]
    /// Executable pinned by the provider; see `LanguageServerExtensionConfiguration.executableURL`.
    package let executableURL: URL?
    package let initializationOptions: ToolingJSONValue?
    /// See `LanguageServerExtensionConfiguration.launchSource`.
    package let launchSource: DeclarativeLanguageServerLaunchSource?
    /// See `LanguageServerExtensionConfiguration.pluginID`.
    package let pluginID: String?
    /// See `LanguageServerExtensionConfiguration.executableVersionRequirement`.
    package let executableVersionRequirement: LanguageServerExecutableVersionRequirement?
    /// See `LanguageServerExtensionConfiguration.launchRuntimeTool`.
    package let launchRuntimeTool: String?

    package init(
        executableNames: [String],
        arguments: [String] = [],
        validationArguments: [String] = [],
        environment: [String: String] = [:],
        runtimeTools: [String] = [],
        executableURL: URL? = nil,
        initializationOptions: ToolingJSONValue? = nil,
        launchSource: DeclarativeLanguageServerLaunchSource? = nil,
        pluginID: String? = nil,
        executableVersionRequirement: LanguageServerExecutableVersionRequirement? = nil,
        launchRuntimeTool: String? = nil
    ) {
        self.executableNames = executableNames
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.environment = environment
        self.runtimeTools = runtimeTools
        self.executableURL = executableURL
        self.initializationOptions = initializationOptions
        self.launchSource = launchSource
        self.pluginID = pluginID ?? launchSource?.pluginID
        self.executableVersionRequirement = executableVersionRequirement
        self.launchRuntimeTool = launchRuntimeTool
    }
}

package struct LanguageServerInstallationDescriptor: Hashable, Sendable {
    package let homebrewFormula: String?
    package let officialDownloadURL: URL?

    package init(homebrewFormula: String?, officialDownloadURL: URL?) {
        self.homebrewFormula = homebrewFormula
        self.officialDownloadURL = officialDownloadURL
    }
}

package struct LanguageProviderDescriptor: Identifiable, Hashable, Sendable {
    package let id: String
    package let displayName: String
    package let fileExtensions: Set<String>
    package let fileNames: Set<String>
    package let fileNamePrefixes: Set<String>
    package let capabilities: LanguageToolingCapability
    package let activationPolicy: ToolingActivationPolicy
    package let languageIdentifier: String?
    package let languageIdentifiersByExtension: [String: String]
    package let languageIdentifiersByFileName: [String: String]
    package let languageServerLaunch: LanguageServerLaunchDescriptor?
    package let languageServerInstallation: LanguageServerInstallationDescriptor?

    package init(
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

    /// The descriptor as a language server session sees it: whether a debugger
    /// exists changes nothing about how the server runs.
    package var withoutDebugAdapter: LanguageProviderDescriptor {
        guard capabilities.contains(.debugAdapter) else { return self }
        return LanguageProviderDescriptor(
            id: id,
            displayName: displayName,
            fileExtensions: fileExtensions,
            fileNames: fileNames,
            fileNamePrefixes: fileNamePrefixes,
            capabilities: capabilities.subtracting(.debugAdapter),
            activationPolicy: activationPolicy,
            languageIdentifier: languageIdentifier,
            languageIdentifiersByExtension: languageIdentifiersByExtension,
            languageIdentifiersByFileName: languageIdentifiersByFileName,
            languageServerLaunch: languageServerLaunch,
            languageServerInstallation: languageServerInstallation
        )
    }

    package func handles(fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent.lowercased()
        return fileExtensions.contains(fileURL.pathExtension.lowercased())
            || fileNames.contains(fileName)
            || fileNamePrefixes.contains { fileName.hasPrefix($0) }
    }

    package func languageIdentifier(for fileURL: URL) -> String {
        let extensionName = fileURL.pathExtension.lowercased()
        let fileName = fileURL.lastPathComponent.lowercased()
        return languageIdentifiersByFileName[fileName]
            ?? languageIdentifiersByExtension[extensionName]
            ?? languageIdentifier
            ?? id
    }
}

package struct LanguageProviderCatalog: Sendable {
    package let descriptors: [LanguageProviderDescriptor]

    package init(descriptors: [LanguageProviderDescriptor]) {
        self.descriptors = descriptors
    }

    /// Minimal fallback used only when the Rust core is not linked. The full
    /// market language catalog is registered by Rust's dedicated LSP config.
    package static let compatibilityFallback = LanguageProviderCatalog(descriptors: [
        LanguageProviderDescriptor(
            id: "go", displayName: "Go", fileExtensions: ["go"],
            capabilities: [.run, .languageServer, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "python", displayName: "Python", fileExtensions: ["py", "pyw"],
            capabilities: [.run, .languageServer, .formatting, .testing],
            activationPolicy: .onDemand
        ),
        LanguageProviderDescriptor(
            id: "node", displayName: "Node.js", fileExtensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"],
            capabilities: [.run, .languageServer, .formatting, .testing],
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
            capabilities: [.run, .languageServer, .formatting, .testing],
            activationPolicy: .onDemand
        ),
    ])

    package func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        descriptors.first { $0.handles(fileURL: fileURL) }
    }
}

package extension LanguageProviderCatalog {
    var debugProviders: [DebugProviderDescriptor] {
        descriptors.compactMap { descriptor in
            guard descriptor.capabilities.contains(.debugAdapter) else { return nil }
            return DebugProviderDescriptor(
                id: descriptor.id,
                displayName: descriptor.displayName,
                fileExtensions: descriptor.fileExtensions,
                fileNames: descriptor.fileNames,
                fileNamePrefixes: descriptor.fileNamePrefixes
            )
        }
    }
}

package struct LanguageServerPosition: Equatable, Sendable {
    package let line: Int
    package let utf16Column: Int

    package init(line: Int, utf16Column: Int) {
        self.line = line
        self.utf16Column = utf16Column
    }
}

package struct LanguageServerRange: Equatable, Sendable {
    package let start: LanguageServerPosition
    package let end: LanguageServerPosition

    package init(start: LanguageServerPosition, end: LanguageServerPosition) {
        self.start = start
        self.end = end
    }
}

package struct LanguageServerDiagnosticRelatedInformation: Equatable, Sendable {
    package let fileURL: URL
    package let range: LanguageServerRange
    package let message: String

    package init(fileURL: URL, range: LanguageServerRange, message: String) {
        self.fileURL = fileURL
        self.range = range
        self.message = message
    }
}

package struct LanguageServerDiagnostic: Equatable, Sendable {
    package let range: LanguageServerRange
    package let severity: Int?
    package let message: String
    package let source: String?
    package let code: String?
    package let tags: [Int]
    package let relatedInformation: [LanguageServerDiagnosticRelatedInformation]

    package init(
        range: LanguageServerRange,
        severity: Int?,
        message: String,
        source: String?,
        code: String?,
        tags: [Int] = [],
        relatedInformation: [LanguageServerDiagnosticRelatedInformation] = []
    ) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
        self.tags = tags
        self.relatedInformation = relatedInformation
    }
}

package struct LanguageServerLocation: Equatable, Sendable {
    package let url: URL
    package let range: LanguageServerRange
    package let isReadOnly: Bool
    package let displayPath: String?

    package init(
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

package struct LanguageServerHover: Equatable, Sendable {
    package let contents: String
    package let isMarkdown: Bool
    package let range: LanguageServerRange?

    package init(contents: String, isMarkdown: Bool, range: LanguageServerRange?) {
        self.contents = contents
        self.isMarkdown = isMarkdown
        self.range = range
    }
}

package struct LanguageServerCompletionItem: Identifiable, Equatable, Sendable {
    package let label: String
    package let detail: String?
    package let documentation: String?
    /// LSP format: 1 is plain text, 2 is a snippet with tab stops.
    package let insertTextFormat: Int
    package let insertText: String
    package let sortText: String?
    package let filterText: String?
    package let kind: Int?
    package let textEdit: LanguageServerTextEdit?
    package let additionalTextEdits: [LanguageServerTextEdit]
    package let data: ToolingJSONValue?

    package init(
        label: String,
        detail: String?,
        documentation: String?,
        insertText: String,
        sortText: String?,
        filterText: String?,
        kind: Int?,
        textEdit: LanguageServerTextEdit?,
        additionalTextEdits: [LanguageServerTextEdit],
        data: ToolingJSONValue?,
        insertTextFormat: Int = 1
    ) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertTextFormat = insertTextFormat
        self.insertText = insertText
        self.sortText = sortText
        self.filterText = filterText
        self.kind = kind
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
        self.data = data
    }

    package var id: String {
        [label, detail ?? "", insertText, sortText ?? ""].joined(separator: "\u{1F}")
    }
}

package struct LanguageServerCommand: Equatable, Sendable {
    package let title: String
    package let command: String
    package let arguments: [ToolingJSONValue]

    package init(title: String, command: String, arguments: [ToolingJSONValue]) {
        self.title = title
        self.command = command
        self.arguments = arguments
    }
}

package enum LanguageServerLogLevel: String, Sendable {
    case info
    case warning
    case error
}

/// What the editor wants from a language server, named by intent rather than by
/// the LSP method that satisfies it. The core maps these to methods and owns the
/// request IDs, so the UI never names a protocol method or reads a raw response.
package enum LanguageServerOperation: String, Equatable, Sendable {
    case completion
    case hover
    case definition
    case declaration
    case typeDefinition
    case references
    case implementation
    case rename
    case formatting
    case codeActions
    case resolveCompletion
    case resolveCodeAction
    case executeCommand
    case inlayHints
    case foldingRanges
    case semanticTokens
    case codeLens
    /// Resolving a server-owned source that has no file on disk, such as a
    /// generated source behind a server-defined URI scheme.
    case virtualDocument
}

/// Server-normalized semantic tokens use zero-based UTF-16 positions.
package struct LanguageServerSemanticTokens: Codable, Equatable, Sendable {
    package struct Token: Codable, Equatable, Sendable {
        package let line: Int
        package let startChar: Int
        package let length: Int
        package let tokenType: Int
        package let tokenModifiers: UInt32
    }
    package let tokenTypes: [String]
    package let tokenModifiers: [String]
    package let tokens: [Token]
    package static let empty = Self(tokenTypes: [], tokenModifiers: [], tokens: [])
}

/// Inline parameter/type annotations returned for a requested document range.
package struct LanguageServerInlayHint: Equatable, Sendable {
    package let position: LanguageServerPosition
    package let label: String
    package let kind: Int?
    package let tooltip: String?
    package let paddingLeft: Bool
    package let paddingRight: Bool
    package let textEdits: [LanguageServerTextEdit]

    package init(position: LanguageServerPosition, label: String, kind: Int?, tooltip: String?,
                 paddingLeft: Bool, paddingRight: Bool, textEdits: [LanguageServerTextEdit]) {
        self.position = position; self.label = label; self.kind = kind; self.tooltip = tooltip
        self.paddingLeft = paddingLeft; self.paddingRight = paddingRight; self.textEdits = textEdits
    }
}

package struct LanguageServerSessionFailure: Equatable, Sendable {
    package let code: String?
    package let stage: String?
    package let exitCode: Int32?
    package let message: String?

    package init(
        code: String? = nil,
        stage: String? = nil,
        exitCode: Int32? = nil,
        message: String? = nil
    ) {
        self.code = code
        self.stage = stage
        self.exitCode = exitCode
        self.message = message
    }

    package var isTimedOut: Bool {
        code == "timed_out" || code == "initializeTimeout" || code == "serviceReadyTimeout"
    }
}

package struct LanguageServerSessionStartError: LocalizedError, Sendable {
    package let failure: LanguageServerSessionFailure

    package init(failure: LanguageServerSessionFailure) {
        self.failure = failure
    }

    package var errorDescription: String? {
        failure.message ?? L10n.string("Language server failed to start.")
    }
}

package enum LanguageServerSessionState: Equatable, Sendable {
    case startingProcess
    case initializing
    case ready
    case stopping
    case stopped
    case failed(LanguageServerSessionFailure)
}

package struct LanguageServerInfo: Equatable, Sendable {
    package let name: String
    package let version: String?

    package init(name: String, version: String?) {
        self.name = name
        self.version = version
    }
}

package struct LanguageServerTextEdit: Equatable, Sendable {
    package let range: LanguageServerRange
    package let newText: String

    package init(range: LanguageServerRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

package struct LanguageServerWorkspaceEdit: Equatable, Sendable {
    package let changes: [URL: [LanguageServerTextEdit]]

    package init(changes: [URL: [LanguageServerTextEdit]] = [:]) {
        self.changes = changes
    }
}

package struct LanguageServerCodeAction: Identifiable, Equatable, Sendable {
    package let title: String
    package let kind: String?
    package let isPreferred: Bool
    package let edit: LanguageServerWorkspaceEdit?
    package let command: LanguageServerCommand?
    package let data: ToolingJSONValue?

    package init(
        title: String,
        kind: String?,
        isPreferred: Bool,
        edit: LanguageServerWorkspaceEdit?,
        command: LanguageServerCommand?,
        data: ToolingJSONValue?
    ) {
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.edit = edit
        self.command = command
        self.data = data
    }

    package var id: String { [title, kind ?? ""].joined(separator: "\u{1F}") }
}

package enum WorkspaceConfigurationUpdateResult: Sendable {
    case applied
    case superseded
    case failed
}

@MainActor
package protocol LanguageServerSession: AnyObject {
    /// The declarative start attempt this session continues: it fails the
    /// attempt before launch or hands it to Core with the start request.
    /// Sessions that never start a declarative process ignore it.
    func observePluginStartup(_ attempt: PluginOperationAttempt)
    /// Called with each server notification Core forwards to the owning
    /// plugin's backend (plan API-25).
    var onPluginServerNotification: ((PluginServerNotification) -> Void)? { get set }
    var isRunning: Bool { get }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)? { get set }
    var onCoreLog: ((CoreLogRecord) -> Void)? { get set }
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)? { get set }
    /// Controlled issue facts: isWarning, source stage, stable code, exit status, operation ID.
    /// No message/detail payload crosses this persistence callback.
    var onLogIssue: ((Bool, String, String, Int?, String?) -> Void)? { get set }
    var onStateChange: ((LanguageServerSessionState) -> Void)? { get set }
    var features: LanguageServerFeatureSet { get }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? { get set }
    var onSemanticTokensRefresh: (() -> Void)? { get set }
    var serverInfo: LanguageServerInfo? { get }
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)? { get set }
    /// Start the language server for the given workspace root.
    func start(rootURL: URL) throws
    func synchronize(fileURL: URL, text: String, languageID: String) throws
    func notifyWorkspaceFilesChanged(_ changes: [LanguageServerWorkspaceFileChange]) throws
    func closeDocument(_ fileURL: URL)
    func completionList(
        fileURL: URL, position: LanguageServerPosition, context: LanguageServerCompletionContext?,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) throws
    func notifyDocumentSaved(_ fileURL: URL, text: String) throws
    func completions(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws
    func inlayHints(fileURL: URL, range: LanguageServerRange,
                    completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void) throws
    func semanticTokens(
        fileURL: URL,
        completion: @escaping (Result<LanguageServerSemanticTokens, Error>) -> Void
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
    func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws
    /// Executes a workspace command with task cancellation. Runtime sessions
    /// cancel the Core operation without stopping the shared language server.
    func executeReturningValue(_ command: LanguageServerCommand, fileURL: URL) async throws -> ToolingJSONValue
    func resolveVirtualDocument(
        uri: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) throws
    /// Sends a `lithe/build/*` request Core planned and returns the reply
    /// undecoded. Cancelling the task cancels the request in the process.
    func buildRequest(method: String, params: ToolingJSONValue, timeout: TimeInterval) async throws
        -> ToolingJSONValue
    /// Replaces the configuration a plugin's server reads through
    /// `workspace/configuration` and announces it; false when the session
    /// cannot take it, so the caller offers a restart instead.
    @discardableResult
    func updateWorkspaceConfiguration(_ configuration: ToolingJSONValue) -> Bool
    /// Sends the same update off the main actor, with the runtime's bounded
    /// send watchdog protecting a server that stopped reading stdin.
    @discardableResult
    func updateWorkspaceConfigurationAsync(_ configuration: ToolingJSONValue) async
        -> WorkspaceConfigurationUpdateResult
    func stop()
    /// Stops the session and confirms process/resource release within a local
    /// deadline. A false result must not be followed by a replacement launch.
    func stopAndWait() async -> Bool
}

package extension LanguageServerSession {
    func observePluginStartup(_ attempt: PluginOperationAttempt) {}

    func stopAndWait() async -> Bool {
        stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while isRunning, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            // log-exempt: 用户取消：调用方取消等待或替换旧任务时结束延迟，不代表操作失败
            catch { return false }
        }
        return !isRunning
    }
}

/// Completion metadata is list-scoped, including when the list is empty.
package struct LanguageServerCompletionList: Sendable {
    package var items: [LanguageServerCompletionItem]
    package var isIncomplete: Bool
    package init(items: [LanguageServerCompletionItem] = [], isIncomplete: Bool = false) {
        self.items = items
        self.isIncomplete = isIncomplete
    }
}

/// LSP trigger kinds: invoked (1), trigger character (2), incomplete-list refresh (3).
package struct LanguageServerCompletionContext: Encodable, Sendable {
    package let triggerKind: Int
    package let triggerCharacter: String?
    package init(triggerKind: Int = 1, triggerCharacter: String? = nil) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
    }
}

package extension LanguageServerSession {
    func completionList(
        fileURL: URL, position: LanguageServerPosition, context: LanguageServerCompletionContext?,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) throws {
        try completions(fileURL: fileURL, position: position) { result in
            completion(result.map { LanguageServerCompletionList(items: $0) })
        }
    }

    @discardableResult
    func updateWorkspaceConfiguration(_: ToolingJSONValue) -> Bool { false }

    @discardableResult
    func updateWorkspaceConfigurationAsync(_: ToolingJSONValue) async -> WorkspaceConfigurationUpdateResult { .failed }

    /// Sends one request of the owning plugin's backend to this server. Core
    /// checks the plugin's whitelist and gates before it reaches the server.
    func requestPluginServer(
        pluginID _: String,
        serverID _: String,
        method _: String,
        params _: ToolingJSONValue,
        timeout _: TimeInterval?
    ) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        .failure(.languageServerUnavailable)
    }

    /// Sends one notification of the owning plugin's backend to this server.
    /// `true` when it was written; `false` when the server is not initialized
    /// yet and reads the stored configuration with `initialized` instead.
    func notifyPluginServer(
        pluginID _: String,
        serverID _: String,
        method _: String,
        params _: ToolingJSONValue
    ) async -> Result<Bool, PluginHostRequestFailure> {
        .failure(.languageServerUnavailable)
    }

    func buildRequest(method _: String, params _: ToolingJSONValue, timeout _: TimeInterval) async throws
        -> ToolingJSONValue {
        throw LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "This language session cannot answer build requests."
        )
    }

    func inlayHints(fileURL: URL, range: LanguageServerRange,
                    completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void) throws {
        completion(.success([]))
    }
    func semanticTokens(fileURL: URL, completion: @escaping (Result<LanguageServerSemanticTokens, Error>) -> Void) throws {
        completion(.success(.empty))
    }
    var onPluginServerNotification: ((PluginServerNotification) -> Void)? {
        get { nil }
        set {}
    }
}

package extension LanguageServerSession {
    func executeReturningValue(_ command: LanguageServerCommand, fileURL: URL) async throws -> ToolingJSONValue {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<ToolingJSONValue, Error>.makeStream()
        try executeReturningValue(command, fileURL: fileURL) { result in
            switch result {
            case .success(let value): continuation.yield(value); continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        defer { continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }

    var onSemanticTokensRefresh: (() -> Void)? {
        get { nil }
        set {}
    }
    var features: LanguageServerFeatureSet { [] }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? {
        get { nil }
        set {}
    }
    var onCoreLog: ((CoreLogRecord) -> Void)? {
        get { nil }
        set { }
    }
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)? {
        get { nil }
        set {}
    }
    var onLogIssue: ((Bool, String, String, Int?, String?) -> Void)? {
        get { nil }
        set {}
    }
    var onStateChange: ((LanguageServerSessionState) -> Void)? {
        get { nil }
        set {}
    }
    func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws {
        try execute(command, fileURL: fileURL) { result in
            completion(result.map { .null })
        }
    }
    var serverInfo: LanguageServerInfo? { nil }
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)? {
        get { nil }
        set {}
    }
    func closeDocument(_: URL) {}
    func notifyDocumentSaved(_: URL, text _: String) throws {}
    func notifyWorkspaceFilesChanged(_: [LanguageServerWorkspaceFileChange]) throws {}
}

@MainActor
package protocol LanguageProviderRuntime: AnyObject {
    var descriptor: LanguageProviderDescriptor { get }
    var supportsLanguageServerSession: Bool { get }
    var unavailableToolingMessage: String? { get }
    func makeLanguageServerSession() -> (any LanguageServerSession)?
    func makeLanguageServerSession(rootURL: URL) -> (any LanguageServerSession)?
}

@MainActor
package protocol LanguageProviderRuntimeFactory: AnyObject {
    func makeRuntime(for descriptor: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)?
    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)?
}

package extension LanguageProviderRuntimeFactory {
    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        makeRuntime(for: descriptor)
    }
}

package extension LanguageProviderRuntime {
    var supportsLanguageServerSession: Bool { false }
    var unavailableToolingMessage: String? { nil }
    func makeLanguageServerSession() -> (any LanguageServerSession)? { nil }
    func makeLanguageServerSession(rootURL: URL) -> (any LanguageServerSession)? { makeLanguageServerSession() }
}
