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
    package let homePath: String
    /// Version reported by `java -version`, such as `25.0.4` or `1.8.0_402`.
    package let version: String

    package init(homePath: String, version: String) {
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

    package init(
        code: String,
        stage: String,
        message: String,
        underlyingMessage: String?,
        processExitCode: Int?,
        javaBuildReport: JavaBuildReport? = nil,
        pluginErrorCode: String? = nil
    ) {
        self.code = code
        self.stage = stage
        self.message = message
        self.underlyingMessage = underlyingMessage
        self.processExitCode = processExitCode
        self.javaBuildReport = javaBuildReport
        self.pluginErrorCode = pluginErrorCode
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

package struct JavaLaunchBuildFailure: Equatable, Sendable {
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
        mavenProfileProject: MavenProfileProjectResult? = nil
    ) {
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

package protocol LanguageServerRuntimeCore: Sendable {
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
        completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
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
    func cancelLanguageServerOperation(sessionID: String, operationID: String)
    func pollLanguageServerEvents(sessionID: String) -> [LanguageServerRuntimeEvent]
    func destroyLanguageServer(sessionID: String)
}

package extension LanguageServerRuntimeCore {
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
