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
    package let initializationOptions: ToolingJSONValue?

    package init(
        executableNames: [String],
        arguments: [String] = [],
        validationArguments: [String] = [],
        environment: [String: String] = [:],
        initializationOptions: ToolingJSONValue? = nil
    ) {
        self.executableNames = executableNames
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.environment = environment
        self.initializationOptions = initializationOptions
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
            id: "java", displayName: "Java", fileExtensions: ["java"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
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
    /// decompiled class behind a `jdt://` URI.
    case virtualDocument
    /// JDT's launchable Java classes in the session workspace, normalized by
    /// Core into workspace-relative entries.
    case javaEntrypoints
    /// Java Test extension classes and methods in one source file, normalized
    /// by Core into a typed tree.
    case javaTestItems
    /// JDT's launchable `main` methods in one source file, with the range of
    /// each method name, normalized by Core.
    case javaMainMethods
}

/// A class JDT confirmed the JVM can launch, as normalized by Core.
///
/// Note: 入口点归属见 .agents/notes/implemented/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md
package struct JavaEntrypoint: Codable, Equatable, Sendable {
    /// Workspace-relative source path with `/` separators.
    package let sourcePath: String
    /// Class name as JDT reports it, possibly prefixed with `module/`.
    package let mainClass: String
    /// JDT project that owns the class; only a hint for resolving the launch.
    package let projectName: String?

    package init(sourcePath: String, mainClass: String, projectName: String? = nil) {
        self.sourcePath = sourcePath
        self.mainClass = mainClass
        self.projectName = projectName
    }
}

/// Core's `javaEntrypoints` answer. Whether a class is launchable is JDT's
/// decision; Lithe never derives entry points from source text.
package struct JavaEntrypoints: Codable, Equatable, Sendable {
    /// A JDT result Core could not turn into an entry, with the reason.
    package struct Diagnostic: Codable, Equatable, Sendable {
        package let code: String
        package let mainClass: String?
        package let detail: String?
    }

    package let schemaVersion: Int
    package let entries: [JavaEntrypoint]
    package let diagnostics: [Diagnostic]

    package init(schemaVersion: Int = 1, entries: [JavaEntrypoint], diagnostics: [Diagnostic] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.diagnostics = diagnostics
    }
}

/// A zero-based UTF-16 source range reported by JDT for a Java test item.
package struct JavaTestRange: Codable, Equatable, Sendable {
    package let startLine: Int
    package let startUtf16Column: Int
    package let endLine: Int
    package let endUtf16Column: Int
}

/// One test class or method whose semantic identity comes from Java Test/JDT.
package struct JavaTestItem: Codable, Equatable, Sendable {
    package let id: String
    package let label: String
    package let fullName: String
    package let projectName: String
    package let kind: Int
    package let level: Int
    package let jdtHandler: String?
    package let sortText: String?
    package let range: JavaTestRange?
    package let children: [JavaTestItem]

    package init(
        id: String,
        label: String,
        fullName: String,
        projectName: String,
        kind: Int,
        level: Int,
        jdtHandler: String? = nil,
        sortText: String? = nil,
        range: JavaTestRange? = nil,
        children: [JavaTestItem] = []
    ) {
        self.id = id
        self.label = label
        self.fullName = fullName
        self.projectName = projectName
        self.kind = kind
        self.level = level
        self.jdtHandler = jdtHandler
        self.sortText = sortText
        self.range = range
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, fullName, projectName, jdtHandler, sortText, range, children
        case kind = "testKind"
        case level = "testLevel"
    }

    package func matches(identifier: String) -> Bool {
        id == identifier || label == identifier || fullName == identifier || jdtHandler == identifier
    }
}

/// One `main` method JDT confirmed the JVM can launch, as normalized by Core.
///
/// Note: 设计见 .agents/notes/implemented/architecture/2026-09-22-editor-run-markers-and-test-outcomes.md
package struct JavaMainMethod: Codable, Equatable, Sendable {
    /// Matches the `mainClass` of the workspace entry point for the same file.
    package let mainClass: String
    package let projectName: String?
    /// Zero-based UTF-16 range of the method name.
    package let range: JavaTestRange

    package init(mainClass: String, projectName: String? = nil, range: JavaTestRange) {
        self.mainClass = mainClass
        self.projectName = projectName
        self.range = range
    }
}

/// Core's `javaMainMethods` answer for one source file.
package struct JavaMainMethods: Codable, Equatable, Sendable {
    package struct Diagnostic: Codable, Equatable, Sendable {
        package let code: String
        package let mainClass: String?
    }

    package let schemaVersion: Int
    package let methods: [JavaMainMethod]
    package let diagnostics: [Diagnostic]

    package init(schemaVersion: Int = 1, methods: [JavaMainMethod], diagnostics: [Diagnostic] = []) {
        self.schemaVersion = schemaVersion
        self.methods = methods
        self.diagnostics = diagnostics
    }
}

/// One IDEA-style editor gutter marker projected by Core's `java.runMarkers`.
package struct JavaRunMarker: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case main
        case testClass
        case testMethod
    }

    package enum Status: String, Codable, Sendable {
        case none
        case passed
        case failed
        case skipped
    }

    /// Zero-based line of the declaration name.
    package let line: Int
    /// Last line of the declaration: body end for tests, name line for `main`.
    package let endLine: Int
    package let kind: Kind
    /// Menu target such as `App.main()`, `OrderTest`, or `OrderTest.creates`.
    package let label: String
    package let mainClass: String?
    package let projectName: String?
    package let testClass: String?
    package let testMethod: String?
    package let testItemId: String?
    package let status: Status

    package init(
        line: Int,
        endLine: Int,
        kind: Kind,
        label: String,
        mainClass: String? = nil,
        projectName: String? = nil,
        testClass: String? = nil,
        testMethod: String? = nil,
        testItemId: String? = nil,
        status: Status = .none
    ) {
        self.line = line
        self.endLine = endLine
        self.kind = kind
        self.label = label
        self.mainClass = mainClass
        self.projectName = projectName
        self.testClass = testClass
        self.testMethod = testMethod
        self.testItemId = testItemId
        self.status = status
    }

    /// Stable identity within one projection, used by editor bridges.
    package var id: String { "\(kind.rawValue):\(line):\(label)" }

    /// The test identifier the Test workflow expects. Runs build a Maven
    /// `-Dtest` selector (`Class#method`); debugging resolves the Java Test
    /// item again, which matches its JDT `id` but not a parameterless name,
    /// because JDT names methods `Class#method()` or `Class#method(Type)`.
    package func testIdentifier(forDebugging: Bool) -> String? {
        guard kind != .main, let testClass else { return nil }
        if forDebugging, let testItemId { return testItemId }
        if kind == .testMethod, let testMethod { return "\(testClass)#\(testMethod)" }
        return testClass
    }

    /// The marker a caret line refers to, following IDEA: the innermost test
    /// method or class whose declaration contains the line, otherwise the
    /// `main` on that line, otherwise the file's first `main`.
    package static func forLine(_ line: Int, in markers: [JavaRunMarker]) -> JavaRunMarker? {
        var enclosing: JavaRunMarker?
        for marker in markers where marker.kind != .main && marker.line <= line && line <= marker.endLine {
            if let current = enclosing,
               marker.line < current.line || (marker.line == current.line && marker.kind != .testMethod) {
                continue
            }
            enclosing = marker
        }
        if let enclosing { return enclosing }
        let mains = markers.filter { $0.kind == .main }
        return mains.first { $0.line == line } ?? mains.first
    }
}

/// Core's normalized Java Test discovery answer.
package struct JavaTestItems: Codable, Equatable, Sendable {
    package struct Diagnostic: Codable, Equatable, Sendable {
        package let code: String
        package let detail: String?
    }

    package let schemaVersion: Int
    package let items: [JavaTestItem]
    package let diagnostics: [Diagnostic]

    package init(
        schemaVersion: Int = 1,
        items: [JavaTestItem],
        diagnostics: [Diagnostic] = []
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.diagnostics = diagnostics
    }
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
        failure.message ?? "Language server failed to start."
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

package struct LanguageServerLogEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let timestamp: Date
    package let providerID: String
    package let operationID: String?
    package let level: LanguageServerLogLevel
    package let message: String
    package let detail: String?

    package init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        providerID: String,
        operationID: String? = nil,
        level: LanguageServerLogLevel,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.providerID = providerID
        self.operationID = operationID
        self.level = level
        self.message = message
        self.detail = detail
    }
}

package struct MavenProfileProjectResult: Equatable, Sendable {
    package let projectURI: URL
    package let status: String
    package let errorDetails: String?

    package init(projectURI: URL, status: String, errorDetails: String? = nil) {
        self.projectURI = projectURI
        self.status = status
        self.errorDetails = errorDetails
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

@MainActor
package protocol LanguageServerSession: AnyObject {
    var onProjectPreparation: ((ProjectPreparationSnapshot) -> Void)? { get set }
    var onMavenProfileTask: ((String) -> Void)? { get set }
    var onMavenProfileProject: ((MavenProfileProjectResult) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Packaged Java Test runner, if this JDT LS session was launched with one.
    var javaTestRunnerURL: URL? { get }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)? { get set }
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)? { get set }
    var onStateChange: ((LanguageServerSessionState) -> Void)? { get set }
    var features: LanguageServerFeatureSet { get }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? { get set }
    var onSemanticTokensRefresh: (() -> Void)? { get set }
    var serverInfo: LanguageServerInfo? { get }
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)? { get set }
    /// Start the language server for the given workspace root.
    /// - Parameter workspaceFingerprint: An opaque digest of the workspace's
    ///   build-system structure. When non-nil, JDT LS uses a per-fingerprint
    ///   state directory so structural changes (add/remove module, edit root
    ///   pom.xml) never reuse a stale project model.
    func start(rootURL: URL, workspaceFingerprint: String?) throws
    func start(
        rootURL: URL,
        workspaceFingerprint: String?,
        mavenContext: MavenLaunchContext?
    ) throws
    func retryMavenProfiles()
    func synchronize(fileURL: URL, text: String, languageID: String) throws
    func notifyWorkspaceFilesChanged(_ changes: [LanguageServerWorkspaceFileChange]) throws
    func closeDocument(_ fileURL: URL)
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
    func resolveVirtualDocument(
        uri: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) throws
    /// JDT's launchable classes in the session workspace, normalized by Core.
    func javaEntrypoints(
        completion: @escaping (Result<JavaEntrypoints, Error>) -> Void
    ) throws
    /// Test classes and methods JDT reports for one source file.
    func javaTestItems(
        fileURL: URL,
        completion: @escaping (Result<JavaTestItems, Error>) -> Void
    ) throws
    /// Launchable `main` methods JDT reports for one source file.
    func javaMainMethods(
        fileURL: URL,
        completion: @escaping (Result<JavaMainMethods, Error>) -> Void
    ) throws
    func javaNavigationMarkers(
        fileURL: URL,
        completion: @escaping (Result<[JavaNavigationMarker], Error>) -> Void
    ) throws
    func resolveJavaNavigation(
        fileURL: URL,
        marker: JavaNavigationMarker,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws
    func stop()
}

package extension LanguageServerSession {
    func inlayHints(fileURL: URL, range: LanguageServerRange,
                    completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void) throws {
        completion(.success([]))
    }
    func semanticTokens(fileURL: URL, completion: @escaping (Result<LanguageServerSemanticTokens, Error>) -> Void) throws {
        completion(.success(.empty))
    }
    var onProjectPreparation: ((ProjectPreparationSnapshot) -> Void)? {
        get { nil }
        set {}
    }
    var onMavenProfileTask: ((String) -> Void)? {
        get { nil }
        set {}
    }
    var onMavenProfileProject: ((MavenProfileProjectResult) -> Void)? {
        get { nil }
        set {}
    }
    func retryMavenProfiles() {}

    func start(
        rootURL: URL,
        workspaceFingerprint: String?,
        mavenContext _: MavenLaunchContext?
    ) throws {
        try start(rootURL: rootURL, workspaceFingerprint: workspaceFingerprint)
    }
}

package extension LanguageServerSession {
    var onSemanticTokensRefresh: (() -> Void)? {
        get { nil }
        set {}
    }
    var features: LanguageServerFeatureSet { [] }
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)? {
        get { nil }
        set {}
    }
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)? {
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
    func notifyWorkspaceFilesChanged(_: [LanguageServerWorkspaceFileChange]) throws {}
    func javaTestItems(
        fileURL _: URL,
        completion: @escaping (Result<JavaTestItems, Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.javaTests))
    }
    func javaMainMethods(
        fileURL _: URL,
        completion: @escaping (Result<JavaMainMethods, Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.javaMainMethods))
    }
    func javaNavigationMarkers(
        fileURL _: URL,
        completion: @escaping (Result<[JavaNavigationMarker], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.javaNavigation))
    }
    func resolveJavaNavigation(
        fileURL _: URL,
        marker _: JavaNavigationMarker,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        completion(.failure(LanguageServerFeatureUnavailable.javaNavigation))
    }
}

private enum LanguageServerFeatureUnavailable: LocalizedError {
    case javaNavigation
    case javaTests
    case javaMainMethods

    var errorDescription: String? {
        switch self {
        case .javaNavigation: "Java navigation is not supported by this language server."
        case .javaTests: "Java test discovery is not supported by this language server."
        case .javaMainMethods: "Java main-method discovery is not supported by this language server."
        }
    }
}

@MainActor
package protocol LanguageProviderRuntime: AnyObject {
    var descriptor: LanguageProviderDescriptor { get }
    var supportsLanguageServerSession: Bool { get }
    var unavailableToolingMessage: String? { get }
    func makeLanguageServerSession() -> (any LanguageServerSession)?
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
}
