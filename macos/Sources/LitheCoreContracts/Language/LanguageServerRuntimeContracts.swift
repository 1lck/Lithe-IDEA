import Foundation
import LitheModuleAPI

/// What a running Java session was asked to do with a Maven configuration.
///
/// Every step runs asynchronously inside JDT LS; resolution problems arrive
/// later as `pom.xml` diagnostics.
package struct LanguageServerMavenConfigurationUpdate: Decodable, Equatable, Sendable {
    /// New settings documents were sent, so JDT LS re-imports every Maven project.
    package let settingsChanged: Bool
    /// Settings were unchanged, so a forced project update was requested.
    package let projectsReloaded: Bool
    /// Changed profiles are being applied.
    package let profilesUpdating: Bool

    package init(settingsChanged: Bool, projectsReloaded: Bool, profilesUpdating: Bool) {
        self.settingsChanged = settingsChanged
        self.projectsReloaded = projectsReloaded
        self.profilesUpdating = profilesUpdating
    }
}

package struct LanguageServerRuntimeFailure: Error, Equatable, Sendable {
    package let code: String
    package let message: String
    package let details: String?

    package init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    package var userMessage: String {
        guard let details, !details.isEmpty else { return message }
        return message + ": " + details
    }
}

package struct LanguageServerRuntimeStart: Equatable, Sendable {
    package let sessionID: String
    package let state: String
    package let processID: Int32?

    package init(sessionID: String, state: String, processID: Int32?) {
        self.sessionID = sessionID
        self.state = state
        self.processID = processID
    }
}

/// An installed JDK the Java language service may compile projects against.
package struct JavaLanguageServiceRuntime: Equatable, Sendable {
    package let isDefault: Bool
    package let homePath: String
    /// Version reported by `java -version`, such as `25.0.4` or `1.8.0_402`.
    package let version: String

    package init(homePath: String, version: String, isDefault: Bool = false) {
        self.isDefault = isDefault
        self.homePath = homePath
        self.version = version
    }
}

package struct JDTLSLaunchResources: Equatable, Sendable {
    package let launcherJarURL: URL
    package let configurationDirectoryURL: URL
    package let lombokAgentURL: URL
    /// Ordered OSGi bundles contributed by Java tooling extensions. The Java
    /// Debug Server remains first for compatibility with older Rust cores.
    package let javaExtensionBundleURLs: [URL]
    /// Standalone TestNG runner used only when a TestNG debug launch is requested.
    package let javaTestRunnerURL: URL?
    /// Installed JDKs, most preferred first. Without them JDT LS knows only the
    /// JDK it runs on and cannot build a project for a newer release.
    package let javaRuntimes: [JavaLanguageServiceRuntime]

    package init(
        launcherJarURL: URL,
        configurationDirectoryURL: URL,
        lombokAgentURL: URL,
        javaDebugBundleURL: URL? = nil,
        javaExtensionBundleURLs: [URL] = [],
        javaTestRunnerURL: URL? = nil,
        javaRuntimes: [JavaLanguageServiceRuntime] = []
    ) {
        self.javaRuntimes = javaRuntimes
        self.launcherJarURL = launcherJarURL.standardizedFileURL
        self.configurationDirectoryURL = configurationDirectoryURL.standardizedFileURL
        self.lombokAgentURL = lombokAgentURL.standardizedFileURL
        var seen = Set<String>()
        self.javaExtensionBundleURLs = ([javaDebugBundleURL].compactMap { $0 } + javaExtensionBundleURLs)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
        self.javaTestRunnerURL = javaTestRunnerURL?.standardizedFileURL
    }

    package var javaDebugBundleURL: URL? {
        javaExtensionBundleURLs.first {
            $0.lastPathComponent.hasPrefix("com.microsoft.java.debug.plugin-")
        }
    }
}

package struct LanguageServerRuntimeOperation: Equatable, Sendable {
    package let operationID: String

    package init(operationID: String) {
        self.operationID = operationID
    }
}

package struct LanguageServerDocumentSync: Equatable, Sendable {
    package let documentVersion: Int
    package let changed: Bool

    package init(documentVersion: Int, changed: Bool) {
        self.documentVersion = documentVersion
        self.changed = changed
    }
}

package struct LanguageServerDocumentPosition: Equatable, Sendable, Codable {
    package let line: Int
    package let utf16Column: Int

    package init(line: Int, utf16Column: Int) {
        self.line = line
        self.utf16Column = utf16Column
    }
}

package struct LanguageServerDocumentChange: Equatable, Sendable, Codable {
    package let start: LanguageServerDocumentPosition
    package let end: LanguageServerDocumentPosition
    package let text: String

    package init(
        start: LanguageServerDocumentPosition,
        end: LanguageServerDocumentPosition,
        text: String
    ) {
        self.start = start
        self.end = end
        self.text = text
    }
}

package protocol IncrementalLanguageServerRuntimeCore {
    func syncLanguageServerDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String,
        changes: [LanguageServerDocumentChange]
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure>
}

package enum LanguageServerWorkspaceFileChangeKind: String, Equatable, Sendable {
    case created
    case changed
    case deleted
}

package struct LanguageServerWorkspaceFileChange: Equatable, Sendable {
    package let fileURL: URL
    package let kind: LanguageServerWorkspaceFileChangeKind

    package init(fileURL: URL, kind: LanguageServerWorkspaceFileChangeKind) {
        self.fileURL = fileURL.standardizedFileURL
        self.kind = kind
    }
}

package enum JavaNavigationDirection: String, Codable, Equatable, Sendable {
    case up
    case down
}

package enum JavaNavigationRelation: String, Codable, Equatable, Sendable {
    case interface
    case inheritance
}

package struct JavaNavigationMarker: Equatable, Sendable {
    package let line: Int
    package let utf16Column: Int
    package let implementationCount: Int
    package let direction: JavaNavigationDirection
    package let relation: JavaNavigationRelation

    package init(
        line: Int,
        utf16Column: Int,
        implementationCount: Int,
        direction: JavaNavigationDirection,
        relation: JavaNavigationRelation
    ) {
        self.line = line
        self.utf16Column = utf16Column
        self.implementationCount = implementationCount
        self.direction = direction
        self.relation = relation
    }
}

package struct LanguageServerRuntimeError: Equatable, Sendable {
    package let code: String
    package let stage: String
    package let message: String
    package let underlyingMessage: String?
    package let processExitCode: Int?
    package let javaBuildReport: JavaBuildReport?
    /// Plugin-defined code of a failed plugin function, for the plugin's own
    /// UI only; the host never branches on it.
    package let pluginErrorCode: String?
    /// Structured facts of a failed plugin-server request. They travel to the
    /// calling backend unchanged as the failure's details.
    package let details: ToolingJSONValue?

    package init(
        code: String,
        stage: String,
        message: String,
        underlyingMessage: String?,
        processExitCode: Int?,
        javaBuildReport: JavaBuildReport? = nil,
        pluginErrorCode: String? = nil,
        details: ToolingJSONValue? = nil
    ) {
        self.code = code
        self.stage = stage
        self.message = message
        self.underlyingMessage = underlyingMessage
        self.processExitCode = processExitCode
        self.javaBuildReport = javaBuildReport
        self.pluginErrorCode = pluginErrorCode
        self.details = details
    }
}

package enum JavaBuildMarkerScope: String, Codable, Equatable, Sendable {
    case launchTarget
    case workspace
}

package enum JavaBuildRecovery: String, Codable, Equatable, Sendable {
    case none
    case rebuildJavaIndex
}

/// Evidence reported by Core for one terminal Java build verdict.
package struct JavaBuildReport: Codable, Equatable, Sendable {
    package let markerScope: JavaBuildMarkerScope
    package let builderFailedEarlier: Bool
    package let elapsedMilliseconds: UInt64
    package let recovery: JavaBuildRecovery

    package init(
        markerScope: JavaBuildMarkerScope,
        builderFailedEarlier: Bool,
        elapsedMilliseconds: UInt64,
        recovery: JavaBuildRecovery
    ) {
        self.markerScope = markerScope
        self.builderFailedEarlier = builderFailedEarlier
        self.elapsedMilliseconds = elapsedMilliseconds
        self.recovery = recovery
    }
}

package struct JavaLaunchBuildFailure: Codable, Equatable, Sendable {
    package let code: String
    package let message: String
    package let report: JavaBuildReport?

    package init(code: String, message: String, report: JavaBuildReport?) {
        self.code = code
        self.message = message
        self.report = report
    }
}

package enum JavaLaunchPreparation: Equatable, Sendable {
    case ready(JavaDebugLaunchTarget)
    case buildFailed(target: JavaDebugLaunchTarget, failure: JavaLaunchBuildFailure)
}

package struct LanguageServerRuntimeEvent: Equatable, Sendable {
    /// Optional structured fact on any runtime event, including stateChanged; independent of type.
    package let coreLog: CoreLogRecord?
    package let pluginID: String?
    package let role: String?
    package let mavenProfileTask: String?
    package let mavenProfileProject: MavenProfileProjectResult?
    package let type: String
    package let state: String?
    package let operationID: String?
    package let uri: String?
    package let diagnostics: [LanguageServerDiagnostic]?
    package let result: ToolingJSONValue?
    package let error: LanguageServerRuntimeError?
    package let capabilities: [String]?
    package let serverInfo: LanguageServerInfo?
    package let level: String?
    package let message: String?
    package let detail: String?
    /// The protocol method the event belongs to, when Core names one.
    package var method: String?

    package init(
        type: String,
        state: String? = nil,
        operationID: String? = nil,
        uri: String? = nil,
        diagnostics: [LanguageServerDiagnostic]? = nil,
        result: ToolingJSONValue? = nil,
        error: LanguageServerRuntimeError? = nil,
        capabilities: [String]? = nil,
        serverInfo: LanguageServerInfo? = nil,
        level: String? = nil,
        message: String? = nil,
        detail: String? = nil,
        mavenProfileTask: String? = nil,
        mavenProfileProject: MavenProfileProjectResult? = nil,
        method: String? = nil,
        coreLog: CoreLogRecord? = nil, pluginID: String? = nil, role: String? = nil
    ) {
        self.coreLog = coreLog; self.pluginID = pluginID; self.role = role
        self.method = method
        self.mavenProfileTask = mavenProfileTask
        self.mavenProfileProject = mavenProfileProject
        self.type = type
        self.state = state
        self.operationID = operationID
        self.uri = uri
        self.diagnostics = diagnostics
        self.result = result
        self.error = error
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.level = level
        self.message = message
        self.detail = detail
    }
}

/// Core-normalized Buildship options, fixed for one Java session's lifetime.
package struct JavaGradleImportConfiguration: Codable, Equatable, Sendable {
    package let wrapperPresent: Bool
    package let offline: Bool?
    package let userHome: String?

    package init(wrapperPresent: Bool, offline: Bool? = nil, userHome: String? = nil) {
        self.wrapperPresent = wrapperPresent
        self.offline = offline
        self.userHome = userHome
    }
}

/// Maven and Gradle can coexist in a workspace; each keeps its own import input.
package struct JavaLanguageImportConfiguration: Equatable, Sendable {
    package let mavenContext: MavenLaunchContext?
    package let javaGradle: JavaGradleImportConfiguration?

    package init(mavenContext: MavenLaunchContext? = nil, javaGradle: JavaGradleImportConfiguration? = nil) {
        self.mavenContext = mavenContext
        self.javaGradle = javaGradle
    }
}

/// Explicit process ownership supplied by each launcher, never inferred from IDs.
package enum LanguageServerLogRole: String, Sendable { case languageServer = "language_server", vcs, build, toolchain, backend }

package protocol LanguageServerRuntimeCore: Sendable {
    /// Core records the result of this declarative start attempt.
    func observingPluginStartup(_ handoff: PluginOperationHandoff) -> any LanguageServerRuntimeCore
    func loggingRuntime(role: LanguageServerLogRole, logSubject: String?, pluginID: String?) -> any LanguageServerRuntimeCore
    func emitCoreLog(_ record: CoreLogRecord)

    /// Network-backed startup must run off the main actor. This is resolved
    /// from the workspace owner, before any process is created.
    func requiresBackgroundLanguageServerStart(rootURL: URL) -> Bool
    func startLanguageServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?,
        jdtlsLaunchResources: JDTLSLaunchResources?,
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    func startLanguageServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?,
        jdtlsLaunchResources: JDTLSLaunchResources?,
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        mavenContext: MavenLaunchContext?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>

    func startLanguageServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?,
        jdtlsLaunchResources: JDTLSLaunchResources?,
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        mavenContext: MavenLaunchContext?,
        javaGradle: JavaGradleImportConfiguration?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>

    func stopLanguageServer(sessionID: String)
    /// Retries a failed Maven profile task without restarting the server.
    func retryMavenProfiles(sessionID: String) -> Result<Void, LanguageServerRuntimeFailure>
    /// Sends a changed Maven context to a running Java session, or with
    /// `reloadProjects` forces JDT LS to re-resolve its Maven projects.
    func updateMavenConfiguration(
        sessionID: String,
        context: MavenLaunchContext,
        reloadProjects: Bool
    ) -> Result<LanguageServerMavenConfigurationUpdate, LanguageServerRuntimeFailure>
    func syncLanguageServerDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure>
    func notifyLanguageServerWorkspaceFilesChanged(
        sessionID: String,
        changes: [LanguageServerWorkspaceFileChange]
    ) -> Result<Void, LanguageServerRuntimeFailure>
    func saveLanguageServerDocument(sessionID: String, fileURL: URL, text: String) -> Result<Bool, LanguageServerRuntimeFailure>
    func closeLanguageServerDocument(sessionID: String, fileURL: URL)
    func requestLanguageServerOperation(
        sessionID: String,
        operation: LanguageServerOperation,
        fileURL: URL?,
        virtualURI: String?,
        position: LanguageServerPosition?,
        newName: String?,
        range: LanguageServerRange?,
        diagnostics: [LanguageServerDiagnostic],
        completionContext: LanguageServerCompletionContext?,
        completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    func prepareJavaLaunch(
        sessionID: String,
        fileURL: URL,
        mainClass: String?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    func requestJavaNavigationMarkers(
        sessionID: String,
        fileURL: URL,
        documentVersion: Int
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    func resolveJavaNavigation(
        sessionID: String,
        fileURL: URL,
        marker: JavaNavigationMarker,
        documentVersion: Int
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Sends a request of the negotiated build-provider protocol. Its
    /// completion arrives as a `requestCompleted` event with the reply under
    /// `result.value`.
    func requestBuildProvider(
        sessionID: String,
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Sends one operation of the negotiated VCS-provider protocol. Its
    /// completion arrives as a `requestCompleted` event with the reply under
    /// `result.value`; a failure carries a `vcs.*` code.
    func requestVcsProvider(
        sessionID: String,
        vcs: String,
        operation: String,
        root: String,
        tool: String?,
        arguments: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Sends one `toolchains/query`. Its completion is a `requestCompleted`
    /// event whose `result.value` is `{ id, response }`, the raw reply the
    /// caller passes to `toolchains.decodeReply` with the same JSON-RPC ID.
    func requestToolchainProvider(
        sessionID: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Sends an import request with an opaque snapshot token to a negotiated provider.
    func requestKeymapImportProvider(
        sessionID: String,
        providerID: String,
        snapshotID: String,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Starts a plugin backend offering its shortcut and optional toolchain providers.
    func startPluginKeymapImportBackend(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        toolchainProviders: [String],
        keymapImportProviders: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    /// Starts a plugin backend and offers it the manifest's toolchain providers.
    func startPluginToolchainBackend(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        toolchainProviders: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    /// Starts a process a plugin owns. Only such a session negotiates plugin
    /// functions, and Core lets it serve that plugin's functions alone.
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    /// Starts a plugin-owned process whose server reads `workspaceConfiguration`
    /// through `workspace/configuration` (plugin settings with `effect: immediate`).
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration: ToolingJSONValue?,
        hostServices: [String],
        hostIntegrationLaunch: LanguageServerHostIntegrationLaunch?,
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        mavenContext: MavenLaunchContext?,
        javaGradle: JavaGradleImportConfiguration?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    /// Starts a plugin-owned server together with the policy that lets the
    /// plugin's backend reach it through the host (plan API-25). Core enforces
    /// `sessionPolicy`: the requests the backend may send, the gates they wait
    /// for and the server notifications it receives.
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration: ToolingJSONValue?,
        sessionPolicy: ToolingJSONValue,
        hostServices: [String],
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    /// Starts a plugin backend that may request the host services named in
    /// `hostServices` (function protocol 2). Core checks every request
    /// against them before publishing a `hostRequest` event.
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>
    /// Answers one `hostRequest` event; Core sends the result, or the
    /// failure as `plugin.host.failed`, to the backend.
    func respondToPluginHostRequest(
        sessionID: String,
        hostRequestID: String,
        outcome: Result<ToolingJSONValue, PluginHostRequestFailure>
    ) -> Result<Void, LanguageServerRuntimeFailure>
    /// Sends a plugin backend one host notification (`lsp.hostNotify`), such
    /// as a subscription event. `true` when Core wrote it; `false` when the
    /// backend negotiated a function protocol without it.
    func notifyPluginBackend(
        sessionID: String,
        method: String,
        params: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure>
    /// Replaces the configuration a running plugin server reads and tells it
    /// through `workspace/didChangeConfiguration`.
    func updateWorkspaceConfiguration(
        sessionID: String,
        configuration: ToolingJSONValue
    ) -> Result<Void, LanguageServerRuntimeFailure>
    /// Invokes a plugin function of `pluginID`. Progress arrives as
    /// `requestProgress` events and the outcome as one `requestCompleted`,
    /// with the result under `result.value`.
    func requestPluginFunction(
        sessionID: String,
        pluginID: String,
        functionID: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Like `requestPluginFunction`, naming the workspace context of the
    /// call. Core forwards it only to a backend that negotiated function
    /// protocol 3; a runtime without contexts drops it.
    func requestPluginFunction(
        sessionID: String,
        pluginID: String,
        functionID: String,
        params: ToolingJSONValue,
        context: PluginWorkspaceContextReference?,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Sends one LSP request of a plugin backend to its own server
    /// (`lsp.pluginServerRequest`). Core checks the plugin's whitelist and
    /// gates; the outcome arrives as one `requestCompleted` event with the
    /// server's result under `result.value`. `timeout` nil keeps Core's default.
    func pluginServerRequest(
        sessionID: String,
        pluginID: String,
        serverID: String,
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure>
    /// Sends one LSP notification of a plugin backend to its own server.
    /// `true` when Core wrote it; `false` when the server is not initialized
    /// yet and reads the stored configuration with `initialized` instead.
    func pluginServerNotify(
        sessionID: String,
        pluginID: String,
        serverID: String,
        method: String,
        params: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure>
    func cancelLanguageServerOperation(sessionID: String, operationID: String)
    func pollLanguageServerEvents(sessionID: String) -> [LanguageServerRuntimeEvent]
    func destroyLanguageServer(sessionID: String)
}

package extension LanguageServerRuntimeCore {
    func observingPluginStartup(_ handoff: PluginOperationHandoff) -> any LanguageServerRuntimeCore { self }
    func loggingRuntime(role: LanguageServerLogRole, logSubject: String?, pluginID: String?) -> any LanguageServerRuntimeCore { self }
    func emitCoreLog(_ record: CoreLogRecord) {}

    func saveLanguageServerDocument(sessionID _: String, fileURL _: URL, text _: String) -> Result<Bool, LanguageServerRuntimeFailure> {
        .success(false)
    }

    func requiresBackgroundLanguageServerStart(rootURL _: URL) -> Bool { false }

    func startLanguageServer(
        providerID: String, executableURL: URL, arguments: [String], environment: [String: String],
        rootURL: URL, workingDirectoryURL: URL, initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?, jdtlsLaunchResources: JDTLSLaunchResources?, cacheDirectoryURL: URL?,
        workspaceFingerprint: String?, mavenContext: MavenLaunchContext?, javaGradle: JavaGradleImportConfiguration?,
        initializeTimeout: TimeInterval, requestTimeout: TimeInterval, shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        guard javaGradle == nil else {
            return .failure(LanguageServerRuntimeFailure(code: "unsupported", message: "This language runtime cannot apply Gradle import settings."))
        }
        return startLanguageServer(
            providerID: providerID, executableURL: executableURL, arguments: arguments, environment: environment,
            rootURL: rootURL, workingDirectoryURL: workingDirectoryURL, initializationOptions: initializationOptions,
            runtimeExecutableURL: runtimeExecutableURL, jdtlsLaunchResources: jdtlsLaunchResources,
            cacheDirectoryURL: cacheDirectoryURL, workspaceFingerprint: workspaceFingerprint, mavenContext: mavenContext,
            initializeTimeout: initializeTimeout, requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    func retryMavenProfiles(sessionID _: String) -> Result<Void, LanguageServerRuntimeFailure> { .success(()) }

    /// Runtimes without in-place Maven updates report that they cannot take
    /// one, so callers fall back to restarting the session.
    func updateMavenConfiguration(
        sessionID _: String,
        context _: MavenLaunchContext,
        reloadProjects _: Bool
    ) -> Result<LanguageServerMavenConfigurationUpdate, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "unsupported",
            message: "This language runtime cannot update Maven settings in place."
        ))
    }

    func startLanguageServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?,
        jdtlsLaunchResources: JDTLSLaunchResources?,
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        mavenContext _: MavenLaunchContext?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startLanguageServer(
            providerID: providerID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: workingDirectoryURL,
            initializationOptions: initializationOptions,
            runtimeExecutableURL: runtimeExecutableURL,
            jdtlsLaunchResources: jdtlsLaunchResources,
            cacheDirectoryURL: cacheDirectoryURL,
            workspaceFingerprint: workspaceFingerprint,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        )
    }
}

package extension LanguageServerRuntimeCore {
    func notifyLanguageServerWorkspaceFilesChanged(
        sessionID _: String,
        changes _: [LanguageServerWorkspaceFileChange]
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        .success(())
    }

    func prepareJavaLaunch(
        sessionID _: String,
        fileURL _: URL,
        mainClass _: String?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(code: "not_supported", message: L10n.string("Java launch preparation is not supported by this runtime.")))
    }

    func requestJavaNavigationMarkers(
        sessionID _: String,
        fileURL _: URL,
        documentVersion _: Int
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Java navigation markers are not supported by this runtime."
        ))
    }

    func resolveJavaNavigation(
        sessionID _: String,
        fileURL _: URL,
        marker _: JavaNavigationMarker,
        documentVersion _: Int
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Java navigation is not supported by this runtime."
        ))
    }

    func requestBuildProvider(
        sessionID _: String,
        method _: String,
        params _: ToolingJSONValue,
        timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Build-provider requests are not supported by this runtime."
        ))
    }

    func requestVcsProvider(
        sessionID _: String,
        vcs _: String,
        operation _: String,
        root _: String,
        tool _: String?,
        arguments _: ToolingJSONValue,
        timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "VCS-provider requests are not supported by this runtime."
        ))
    }

    func requestToolchainProvider(
        sessionID _: String,
        params _: ToolingJSONValue,
        timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Toolchain-provider requests are not supported by this runtime."
        ))
    }

    func requestKeymapImportProvider(
        sessionID _: String, providerID _: String, snapshotID _: String, timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(code: "not_supported", message: L10n.string(
            "Shortcut import is unavailable. Update Lithe and the editor import plugin, then try again."
        )))
    }

    func startPluginKeymapImportBackend(
        pluginID _: String, providerID _: String, executableURL _: URL, arguments _: [String],
        environment _: [String: String], rootURL _: URL, initializationOptions _: ToolingJSONValue?,
        hostServices _: [String], toolchainProviders _: [String], keymapImportProviders _: [String],
        initializeTimeout _: TimeInterval, requestTimeout _: TimeInterval, shutdownTimeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(code: "not_supported", message: L10n.string(
            "Shortcut import is unavailable. Update Lithe and the editor import plugin, then try again."
        )))
    }

    /// Runtimes without the protocol start the backend without the offer, so
    /// it negotiates no provider and receives no query.
    func startPluginToolchainBackend(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        toolchainProviders _: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startPluginLanguageServer(
            pluginID: pluginID, providerID: providerID, executableURL: executableURL, arguments: arguments,
            environment: environment, rootURL: rootURL, initializationOptions: initializationOptions,
            hostServices: hostServices,
            initializeTimeout: initializeTimeout, requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    /// Runtimes without plugin ownership start a host-owned session, which
    /// serves no plugin functions.
    func startPluginLanguageServer(
        pluginID _: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startLanguageServer(
            providerID: providerID, executableURL: executableURL, arguments: arguments, environment: environment,
            rootURL: rootURL, workingDirectoryURL: rootURL, initializationOptions: initializationOptions,
            runtimeExecutableURL: nil, jdtlsLaunchResources: nil, cacheDirectoryURL: nil,
            workspaceFingerprint: nil, initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    /// Runtimes that cannot enforce a session policy start the process as a
    /// plain plugin backend: without the policy, so the plugin's backend has
    /// no route to the server, and without workspace configuration.
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration _: ToolingJSONValue?,
        sessionPolicy _: ToolingJSONValue,
        hostServices: [String],
        cacheDirectoryURL _: URL?,
        workspaceFingerprint _: String?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startPluginLanguageServer(
            pluginID: pluginID, providerID: providerID, executableURL: executableURL, arguments: arguments,
            environment: environment, rootURL: rootURL, initializationOptions: initializationOptions,
            hostServices: hostServices,
            initializeTimeout: initializeTimeout, requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    /// Runtimes without plugin configuration support ignore it.
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration _: ToolingJSONValue?,
        hostServices: [String],
        hostIntegrationLaunch: LanguageServerHostIntegrationLaunch?,
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        mavenContext: MavenLaunchContext?,
        javaGradle: JavaGradleImportConfiguration?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        if let hostIntegrationLaunch, hostServices.isEmpty {
            return startLanguageServer(
                providerID: providerID, executableURL: executableURL, arguments: arguments,
                environment: environment, rootURL: rootURL, workingDirectoryURL: rootURL,
                initializationOptions: initializationOptions,
                runtimeExecutableURL: hostIntegrationLaunch.runtimeExecutableURL,
                jdtlsLaunchResources: hostIntegrationLaunch.coreLaunch?.jdtlsLaunchResources,
                cacheDirectoryURL: cacheDirectoryURL, workspaceFingerprint: workspaceFingerprint,
                mavenContext: mavenContext, javaGradle: javaGradle,
                initializeTimeout: initializeTimeout, requestTimeout: requestTimeout,
                shutdownTimeout: shutdownTimeout
            )
        }
        return startPluginLanguageServer(
            pluginID: pluginID, providerID: providerID, executableURL: executableURL, arguments: arguments,
            environment: environment, rootURL: rootURL, initializationOptions: initializationOptions,
            hostServices: hostServices,
            initializeTimeout: initializeTimeout, requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    /// Runtimes without host services start the backend only when it
    /// needs none.
    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        guard hostServices.isEmpty else {
            return .failure(LanguageServerRuntimeFailure(
                code: "not_supported",
                message: "Plugin host services are not supported by this runtime."
            ))
        }
        return startPluginLanguageServer(
            pluginID: pluginID, providerID: providerID, executableURL: executableURL, arguments: arguments,
            environment: environment, rootURL: rootURL, initializationOptions: initializationOptions,
            initializeTimeout: initializeTimeout, requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    func respondToPluginHostRequest(
        sessionID _: String,
        hostRequestID _: String,
        outcome _: Result<ToolingJSONValue, PluginHostRequestFailure>
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Plugin host services are not supported by this runtime."
        ))
    }

    func notifyPluginBackend(
        sessionID _: String,
        method _: String,
        params _: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Plugin host notifications are not supported by this runtime."
        ))
    }

    func updateWorkspaceConfiguration(
        sessionID _: String,
        configuration _: ToolingJSONValue
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Workspace configuration updates are not supported by this runtime."
        ))
    }

    func requestPluginFunction(
        sessionID: String,
        pluginID: String,
        functionID: String,
        params: ToolingJSONValue,
        context _: PluginWorkspaceContextReference?,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        requestPluginFunction(
            sessionID: sessionID, pluginID: pluginID, functionID: functionID, params: params, timeout: timeout
        )
    }

    func requestPluginFunction(
        sessionID _: String,
        pluginID _: String,
        functionID _: String,
        params _: ToolingJSONValue,
        timeout _: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Plugin functions are not supported by this runtime."
        ))
    }

    func pluginServerRequest(
        sessionID _: String,
        pluginID _: String,
        serverID _: String,
        method _: String,
        params _: ToolingJSONValue,
        timeout _: TimeInterval?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Plugin language server requests are not supported by this runtime."
        ))
    }

    func pluginServerNotify(
        sessionID _: String,
        pluginID _: String,
        serverID _: String,
        method _: String,
        params _: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure> {
        .failure(LanguageServerRuntimeFailure(
            code: "not_supported",
            message: "Plugin language server notifications are not supported by this runtime."
        ))
    }
}

/// A host-service request a plugin backend sent, after Core checked its
/// method, grant, and params (function protocol 2).
package struct PluginHostRequest: Equatable, Sendable {
    /// Core's ID for `lsp.hostResponse`.
    package let id: String
    package let method: String
    /// The granted service the method belongs to, such as `credentials`.
    package let service: String
    package let params: ToolingJSONValue

    package init(id: String, method: String, service: String, params: ToolingJSONValue) {
        self.id = id
        self.method = method
        self.service = service
        self.params = params
    }
}

/// The host could not complete a host-service request. The message reaches
/// the backend; never put a secret in it. `code` is a `plugin.host.*` code
/// Core passes to a function protocol 3 backend; nil, or a code Core does
/// not pass, reaches it as `plugin.host.failed`. `details` is an object of
/// facts the backend may act on, such as a document's current version; Core
/// passes it within 4 KiB to a protocol 3 backend and drops it otherwise.
package struct PluginHostRequestFailure: Error, Equatable, Sendable {
    package let message: String
    package let code: String?
    package let details: ToolingJSONValue?

    package init(message: String, code: String? = nil, details: ToolingJSONValue? = nil) {
        self.message = message
        self.code = code
        self.details = details
    }
}

package extension PluginHostRequestFailure {
    /// The backend's own server is not there to answer: stopped, still
    /// starting, or never started with a session policy.
    static let languageServerUnavailable = PluginHostRequestFailure(
        message: "The language server is not running.", code: "plugin.host.languageServerUnavailable"
    )

    /// The server the backend named belongs to another plugin. A plugin may
    /// only talk to the servers its own package declares.
    static let foreignContribution = PluginHostRequestFailure(
        message: "The language server belongs to another plugin.", code: "plugin.host.foreignContribution"
    )

    /// Core refused the call before it reached the server. Core puts the
    /// stable `plugin.host.*` code in `details`; any other diagnostic there
    /// never becomes the code the backend sees.
    init(refusal failure: LanguageServerRuntimeFailure) {
        let code = failure.details.flatMap { $0.hasPrefix("plugin.host.") ? $0 : nil }
        self.init(message: failure.message, code: code ?? "plugin.host.languageServerUnavailable")
    }

    /// The server's answer was an error. Core already mapped its code to a
    /// `plugin.host.*` code and put the server's own `{ code, message }` in
    /// `details`; the backend receives both unchanged.
    init(completion error: LanguageServerRuntimeError, message: String) {
        let code = error.code.hasPrefix("plugin.host.") ? error.code : "plugin.host.languageServerUnavailable"
        self.init(message: message, code: code, details: error.details)
    }
}

/// A server notification Rust Core forwarded because the plugin's manifest
/// lists its method in `forwardNotifications`. `params` is nil when the
/// payload was too large; the backend then asks the server for the state.
package struct PluginServerNotification: Equatable, Sendable {
    package let method: String
    package let params: ToolingJSONValue?
    package let truncated: Bool

    package init(method: String, params: ToolingJSONValue?, truncated: Bool) {
        self.method = method
        self.params = params
        self.truncated = truncated
    }
}

/// One generation of one workspace context, as a call or a host request
/// names it (function protocol 3). Only the host decides whether it is
/// still current.
package struct PluginWorkspaceContextReference: Hashable, Sendable {
    package let contextID: String
    package let generation: Int

    package init(contextID: String, generation: Int) {
        self.contextID = contextID
        self.generation = generation
    }
}

/// One progress report of a running plugin function, as Core normalized it.
package struct PluginFunctionProgress: Equatable, Sendable {
    package let message: String?
    /// A whole number from 0 to 100.
    package let percentage: Int?

    package init(message: String?, percentage: Int?) {
        self.message = message
        self.percentage = percentage
    }
}

/// A plugin function that ended without a result: Core's stable
/// `plugin.function.*` or request code, and the backend's own code when it
/// gave one. Cancellation is reported as `CancellationError` instead.
package struct PluginFunctionFailure: LocalizedError, Equatable, Sendable {
    package let code: String
    package let message: String
    package let pluginErrorCode: String?

    package init(code: String, message: String, pluginErrorCode: String? = nil) {
        self.code = code
        self.message = message
        self.pluginErrorCode = pluginErrorCode
    }

    package var errorDescription: String? { message }
}

@MainActor
package protocol LanguageServerProcessRegistry: AnyObject {
    func registerLanguageServerProcess(pid: Int32, moduleID: ModuleID)
    func unregisterLanguageServerProcess(pid: Int32, moduleID: ModuleID)
}

/// Read-only preparation facts published by Rust; ready does not imply a successful build.
package struct ProjectPreparationSnapshot: Codable, Equatable, Sendable {
    package let phase: String
    package let status: String
    package let blocksRun: Bool

    package init(phase: String, status: String, blocksRun: Bool) {
        self.phase = phase
        self.status = status
        self.blocksRun = blocksRun
    }
}
