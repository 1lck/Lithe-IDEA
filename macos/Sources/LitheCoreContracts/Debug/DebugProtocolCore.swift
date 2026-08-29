import Foundation

/// Lifecycle state reduced by the shared Rust Debug Core.
public enum DebugCoreSessionState: String, Decodable, Equatable, Sendable {
    case idle, initializing, ready, launching, running, paused, terminating, terminated, failed
}

/// One deterministic reduction returned by a shared Debug Core command.
public struct DebugCoreUpdate: Decodable, Equatable, Sendable {
    public let sessionID: String
    public let state: DebugCoreSessionState
    public let outboundFrames: [String]
    public let events: [DebugCoreEvent]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case state
        case outboundFrames
        case events
    }
}

/// A normalized event emitted by the shared Debug Core.
public struct DebugCoreEvent: Decodable, Equatable, Sendable {
    public let sequence: UInt64
    public let type: String
    public let state: DebugCoreSessionState?
    public let category: String?
    public let output: String?
    public let reason: String?
    public let threadID: Int?
    public let description: String?
    public let exitCode: Int?
    public let breakpoint: DebugCoreBreakpoint?
    public let capabilities: DebugCoreCapabilities?
    public let operationID: String?
    public let result: DebugCoreOperationResult?
    public let command: String?
    public let code: String?
    public let message: String?

    private enum CodingKeys: String, CodingKey {
        case sequence
        case type
        case state
        case category
        case output
        case reason
        case threadID = "threadId"
        case description
        case exitCode
        case breakpoint
        case capabilities
        case operationID = "operationId"
        case result
        case command
        case code
        case message
    }
}

public struct DebugCoreCapabilities: Decodable, Equatable, Sendable {
    public let supportsConfigurationDone: Bool
    public let supportsConditionalBreakpoints: Bool
    public let supportsHitConditionalBreakpoints: Bool
    public let supportsLogPoints: Bool
    public let supportsFunctionBreakpoints: Bool
    public let supportsDataBreakpoints: Bool
    public let supportsExceptionOptions: Bool
    public let supportsExceptionFilterOptions: Bool
    public let supportsSetVariable: Bool
    public let supportsCancelRequest: Bool
    public let supportsSingleThreadExecutionRequests: Bool
    public let supportsRestartRequest: Bool
    public let supportsTerminateRequest: Bool
    public let supportsStepBack: Bool
    public let supportsExceptionInfoRequest: Bool
    public let supportsStepInTargetsRequest: Bool
    public let supportsGotoTargetsRequest: Bool
    public let exceptionBreakpointFilters: [DebugExceptionBreakpointFilter]
}

public struct DebugCoreOperationResult: Decodable, Equatable, Sendable {
    public let kind: String
    public let command: String?
    public let threads: [DebugCoreThread]?
    public let stackFrames: [DebugCoreStackFrame]?
    public let scopes: [DebugCoreScope]?
    public let variables: [DebugCoreVariable]?
    public let variable: DebugCoreVariable?
    public let exceptionInfo: DebugCoreExceptionInfo?
    public let dataID: String?
    public let description: String?
    public let accessTypes: [String]?
    public let canPersist: Bool?
    public let targets: [DebugCoreTarget]?

    private enum CodingKeys: String, CodingKey {
        case kind, command, threads, stackFrames, scopes, variables, variable, exceptionInfo
        case dataID = "dataId"
        case description, accessTypes, canPersist, targets
    }
}

public struct DebugCoreTarget: Decodable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let line: Int?
    public let column: Int?
    public let endLine: Int?
    public let endColumn: Int?
    public let instructionPointerReference: String?
}

public struct DebugCoreBreakpoint: Decodable, Equatable, Sendable {
    public let id: Int
    public let verified: Bool
    public let message: String?
    public let functionName: String?
    public let dataID: String?
    public let sourcePath: String?
    public let line: Int?
    public let column: Int?

    private enum CodingKeys: String, CodingKey {
        case id, verified, message, functionName
        case dataID = "dataId"
        case sourcePath, line, column
    }
}

public struct DebugCoreThread: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
}

public struct DebugCoreStackFrame: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let sourcePath: String?
    public let line: Int
    public let column: Int
    public let isFiltered: Bool

    public init(
        id: Int,
        name: String,
        sourcePath: String?,
        line: Int,
        column: Int,
        isFiltered: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.line = line
        self.column = column
        self.isFiltered = isFiltered
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourcePath, line, column, isFiltered
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        line = try container.decode(Int.self, forKey: .line)
        column = try container.decode(Int.self, forKey: .column)
        isFiltered = try container.decodeIfPresent(Bool.self, forKey: .isFiltered) ?? false
    }
}

public struct DebugCoreScope: Decodable, Equatable, Sendable {
    public let name: String
    public let variablesReference: Int
    public let expensive: Bool
}

public struct DebugCoreVariable: Decodable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let type: String?
    public let evaluateName: String?
    public let variablesReference: Int
}

public struct DebugCoreExceptionInfo: Decodable, Equatable, Sendable {
    public let exceptionID: String
    public let description: String?
    public let breakMode: String
    public let details: DebugCoreExceptionDetails?

    private enum CodingKeys: String, CodingKey {
        case exceptionID = "exceptionId"
        case description, breakMode, details
    }
}

public struct DebugCoreExceptionDetails: Decodable, Equatable, Sendable {
    public let message: String?
    public let typeName: String?
    public let fullTypeName: String?
    public let evaluateName: String?
    public let stackTrace: String?
    public let innerExceptions: [DebugCoreExceptionDetails]
}

/// Focused policy boundary for portable debugger stepping defaults and validation.
@MainActor
public protocol DebugSteppingFilterResolving: Sendable {
    func resolveDebugSteppingFilters(
        adapterID: String,
        filters: DebugSteppingFilters?
    ) throws -> DebugSteppingFilters
}

/// Transport-neutral Debug Core boundary. Native products own processes and
/// sockets; this contract owns DAP framing, state, sequencing, and normalized data.
@MainActor
public protocol DebugProtocolCore: DebugSteppingFilterResolving, Sendable {
    func createDebugSession(
        sessionID: String,
        adapterID: String,
        rootPath: String
    ) throws -> DebugCoreUpdate
    func launchDebugSession(
        sessionID: String,
        operationID: String,
        configuration: DebugLaunchConfiguration
    ) throws -> DebugCoreUpdate
    func setDebugBreakpoints(
        sessionID: String,
        sourcePath: String,
        breakpoints: [DebugSourceBreakpoint]
    ) throws -> DebugCoreUpdate
    func setDebugExceptionBreakpoints(
        sessionID: String,
        breakpoints: [DebugExceptionBreakpoint]
    ) throws -> DebugCoreUpdate
    func setDebugFunctionBreakpoints(
        sessionID: String,
        breakpoints: [DebugFunctionBreakpoint]
    ) throws -> DebugCoreUpdate
    func debugDataBreakpointInfo(
        sessionID: String,
        operationID: String,
        name: String,
        variablesReference: Int?,
        frameID: Int?
    ) throws -> DebugCoreUpdate
    func setDebugDataBreakpoints(
        sessionID: String,
        breakpoints: [DebugDataBreakpoint]
    ) throws -> DebugCoreUpdate
    func setDebugVariable(
        sessionID: String,
        operationID: String,
        variablesReference: Int,
        name: String,
        value: String
    ) throws -> DebugCoreUpdate
    func cancelDebugOperation(
        sessionID: String,
        operationID: String,
        reason: String
    ) throws -> DebugCoreUpdate
    func executeDebugCommand(
        sessionID: String,
        operationID: String,
        command: DebugExecutionCommand,
        threadID: Int?,
        targetID: Int?,
        singleThread: Bool
    ) throws -> DebugCoreUpdate
    func inspectDebugSession(
        sessionID: String,
        operationID: String,
        kind: String,
        threadID: Int?,
        frameID: Int?,
        variablesReference: Int?,
        expression: String?,
        sourcePath: String?,
        line: Int?,
        column: Int?
    ) throws -> DebugCoreUpdate
    func receiveDebugData(sessionID: String, data: Data) throws -> DebugCoreUpdate
    func disconnectDebugSession(sessionID: String) throws -> DebugCoreUpdate
    func destroyDebugSession(sessionID: String)
}
