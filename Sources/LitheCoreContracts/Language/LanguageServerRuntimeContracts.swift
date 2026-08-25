import Foundation
import LitheModuleAPI

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

    package init(
        code: String,
        stage: String,
        message: String,
        underlyingMessage: String?,
        processExitCode: Int?
    ) {
        self.code = code
        self.stage = stage
        self.message = message
        self.underlyingMessage = underlyingMessage
        self.processExitCode = processExitCode
    }
}

package struct LanguageServerRuntimeEvent: Equatable, Sendable {
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
        detail: String? = nil
    ) {
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
        cacheDirectoryURL: URL?,
        workspaceFingerprint: String?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure>

    func stopLanguageServer(sessionID: String)
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
    func cancelLanguageServerOperation(sessionID: String, operationID: String)
    func pollLanguageServerEvents(sessionID: String) -> [LanguageServerRuntimeEvent]
    func destroyLanguageServer(sessionID: String)
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
}

@MainActor
package protocol LanguageServerProcessRegistry: AnyObject {
    func registerLanguageServerProcess(pid: Int32, moduleID: ModuleID)
    func unregisterLanguageServerProcess(pid: Int32, moduleID: ModuleID)
}
