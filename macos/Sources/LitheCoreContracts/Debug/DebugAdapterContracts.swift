import Foundation

@MainActor
public protocol DebugAdapterSession: AnyObject {
    var isRunning: Bool { get }
    var state: DebugAdapterState { get }
    func start(rootURL: URL) throws
    func stop()
}

@MainActor
public protocol DebugAdapterTransport: AnyObject {
    var isRunning: Bool { get }
    var onData: ((Data) -> Void)? { get set }
    var onErrorOutput: ((Data) -> Void)? { get set }
    var onTermination: ((Int) -> Void)? { get set }
    func start(rootURL: URL) throws
    func send(_ data: Data) throws
    func stop()
}

@MainActor
public protocol DebugAdapterChildTransportProviding: AnyObject {
    func makeChildTransport() -> (any DebugAdapterTransport)?
}

@MainActor
public protocol DebugOperationDeadline: AnyObject {
    func cancel()
}

@MainActor
public protocol DebugOperationDeadlineScheduling: AnyObject {
    func schedule(
        afterMilliseconds: Int,
        action: @escaping @MainActor () -> Void
    ) -> any DebugOperationDeadline
}

public extension DebugAdapterSession {
    var state: DebugAdapterState { isRunning ? .running : .idle }
}

public enum DebugAdapterState: String, Equatable, Sendable {
    case idle, initializing, ready, launching, running, paused, terminated, failed
}

public enum DebugRequestKind: String, Codable, Equatable, Sendable {
    case launch, attach
}

public struct DebugLaunchConfiguration: Codable, Equatable, Sendable {
    public let name: String
    public let request: DebugRequestKind
    public let arguments: [String: ToolingJSONValue]
    public let steppingFilters: DebugSteppingFilters?

    public init(
        name: String,
        request: DebugRequestKind,
        arguments: [String: ToolingJSONValue],
        steppingFilters: DebugSteppingFilters? = nil
    ) {
        self.name = name
        self.request = request
        self.arguments = arguments
        self.steppingFilters = steppingFilters
    }

    public func applying(steppingFilters: DebugSteppingFilters) -> Self {
        Self(
            name: name,
            request: request,
            arguments: arguments,
            steppingFilters: steppingFilters
        )
    }
}

public struct DebugSteppingFilters: Codable, Equatable, Sendable {
    public let classNameFilters: [String]
    public let skipSynthetics: Bool
    public let skipStaticInitializers: Bool
    public let skipConstructors: Bool
    public let hideFilteredStackFrames: Bool

    public init(
        classNameFilters: [String],
        skipSynthetics: Bool,
        skipStaticInitializers: Bool,
        skipConstructors: Bool,
        hideFilteredStackFrames: Bool
    ) {
        self.classNameFilters = classNameFilters
        self.skipSynthetics = skipSynthetics
        self.skipStaticInitializers = skipStaticInitializers
        self.skipConstructors = skipConstructors
        self.hideFilteredStackFrames = hideFilteredStackFrames
    }
}

/// JDT LS-owned identity for one Java launch target. `mainClass` may include
/// the JPMS module prefix (`module/name.Type`) required by Java Debug Server.
public struct JavaDebugLaunchTarget: Equatable, Sendable {
    public let mainClass: String
    public let projectName: String?
    public let modulePaths: [String]
    public let classPaths: [String]

    public init(
        mainClass: String,
        projectName: String?,
        modulePaths: [String] = [],
        classPaths: [String] = []
    ) {
        self.mainClass = mainClass
        self.projectName = projectName
        self.modulePaths = modulePaths
        self.classPaths = classPaths
    }
}

public struct DebugSourceBreakpoint: Codable, Hashable, Sendable {
    public let line: Int
    public let column: Int?
    public let enabled: Bool
    public let condition: String?
    public let hitCondition: String?
    public let logMessage: String?

    public init(
        line: Int,
        column: Int? = nil,
        enabled: Bool = true,
        condition: String? = nil,
        hitCondition: String? = nil,
        logMessage: String? = nil
    ) {
        self.line = line
        self.column = column
        self.enabled = enabled
        self.condition = condition
        self.hitCondition = hitCondition
        self.logMessage = logMessage
    }
}

public struct DebugBreakpoint: Identifiable, Equatable, Sendable {
    public let id: Int
    public let verified: Bool
    public let message: String?
    public let functionName: String?
    public let dataID: String?
    public let sourceURL: URL?
    public let line: Int?
    public let column: Int?

    public init(
        id: Int,
        verified: Bool,
        message: String?,
        sourceURL: URL?,
        line: Int?,
        column: Int?,
        functionName: String? = nil,
        dataID: String? = nil
    ) {
        self.id = id
        self.verified = verified
        self.message = message
        self.functionName = functionName
        self.dataID = dataID
        self.sourceURL = sourceURL
        self.line = line
        self.column = column
    }
}

public struct DebugExceptionBreakpointFilter: Codable, Equatable, Sendable {
    public let filter: String
    public let label: String
    public let description: String?
    public let isDefault: Bool
    public let supportsCondition: Bool
    public let conditionDescription: String?

    public init(
        filter: String,
        label: String,
        description: String?,
        isDefault: Bool,
        supportsCondition: Bool,
        conditionDescription: String?
    ) {
        self.filter = filter
        self.label = label
        self.description = description
        self.isDefault = isDefault
        self.supportsCondition = supportsCondition
        self.conditionDescription = conditionDescription
    }

    private enum CodingKeys: String, CodingKey {
        case filter, label, description
        case isDefault = "default"
        case supportsCondition, conditionDescription
    }
}

public struct DebugExceptionBreakpoint: Codable, Hashable, Sendable {
    public let filter: String
    public let enabled: Bool
    public let condition: String?

    public init(filter: String, enabled: Bool = true, condition: String? = nil) {
        self.filter = filter
        self.enabled = enabled
        self.condition = condition
    }
}

public struct DebugFunctionBreakpoint: Codable, Hashable, Sendable {
    public let name: String
    public let enabled: Bool
    public let condition: String?
    public let hitCondition: String?

    public init(
        name: String,
        enabled: Bool = true,
        condition: String? = nil,
        hitCondition: String? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.condition = condition
        self.hitCondition = hitCondition
    }
}

public struct DebugDataBreakpoint: Codable, Hashable, Sendable {
    public let dataID: String
    public let label: String?
    public let enabled: Bool
    public let accessType: String?
    public let condition: String?
    public let hitCondition: String?

    public init(
        dataID: String,
        label: String? = nil,
        enabled: Bool = true,
        accessType: String? = nil,
        condition: String? = nil,
        hitCondition: String? = nil
    ) {
        self.dataID = dataID
        self.label = label
        self.enabled = enabled
        self.accessType = accessType
        self.condition = condition
        self.hitCondition = hitCondition
    }

    private enum CodingKeys: String, CodingKey {
        case dataID = "dataId"
        case label, enabled, accessType, condition, hitCondition
    }
}

public struct DebugDataBreakpointInfo: Equatable, Sendable {
    public let dataID: String?
    public let description: String
    public let accessTypes: [String]
    public let canPersist: Bool

    public init(dataID: String?, description: String, accessTypes: [String], canPersist: Bool) {
        self.dataID = dataID
        self.description = description
        self.accessTypes = accessTypes
        self.canPersist = canPersist
    }
}

public struct DebugExceptionInfo: Equatable, Sendable {
    public let exceptionID: String
    public let description: String?
    public let breakMode: String
    public let details: DebugExceptionDetails?

    public init(
        exceptionID: String,
        description: String?,
        breakMode: String,
        details: DebugExceptionDetails?
    ) {
        self.exceptionID = exceptionID
        self.description = description
        self.breakMode = breakMode
        self.details = details
    }
}

public struct DebugExceptionDetails: Equatable, Sendable {
    public let message: String?
    public let typeName: String?
    public let fullTypeName: String?
    public let evaluateName: String?
    public let stackTrace: String?
    public let innerExceptions: [DebugExceptionDetails]

    public init(
        message: String?,
        typeName: String?,
        fullTypeName: String?,
        evaluateName: String?,
        stackTrace: String?,
        innerExceptions: [DebugExceptionDetails] = []
    ) {
        self.message = message
        self.typeName = typeName
        self.fullTypeName = fullTypeName
        self.evaluateName = evaluateName
        self.stackTrace = stackTrace
        self.innerExceptions = innerExceptions
    }
}

public struct DebugStepInTarget: Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let line: Int?
    public let column: Int?
    public let endLine: Int?
    public let endColumn: Int?

    public init(
        id: Int,
        label: String,
        line: Int?,
        column: Int?,
        endLine: Int?,
        endColumn: Int?
    ) {
        self.id = id
        self.label = label
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

public struct DebugGotoTarget: Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let line: Int
    public let column: Int?
    public let endLine: Int?
    public let endColumn: Int?
    public let instructionPointerReference: String?

    public init(
        id: Int,
        label: String,
        line: Int,
        column: Int?,
        endLine: Int?,
        endColumn: Int?,
        instructionPointerReference: String?
    ) {
        self.id = id
        self.label = label
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.instructionPointerReference = instructionPointerReference
    }
}

public struct DebugAdapterCapabilities: Equatable, Sendable {
    public let negotiated: Bool
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

    public static let unknown = DebugAdapterCapabilities()

    public init(
        negotiated: Bool = false,
        supportsConfigurationDone: Bool = false,
        supportsConditionalBreakpoints: Bool = false,
        supportsHitConditionalBreakpoints: Bool = false,
        supportsLogPoints: Bool = false,
        supportsFunctionBreakpoints: Bool = false,
        supportsDataBreakpoints: Bool = false,
        supportsExceptionOptions: Bool = false,
        supportsExceptionFilterOptions: Bool = false,
        supportsSetVariable: Bool = false,
        supportsCancelRequest: Bool = false,
        supportsSingleThreadExecutionRequests: Bool = false,
        supportsRestartRequest: Bool = false,
        supportsTerminateRequest: Bool = false,
        supportsStepBack: Bool = false,
        supportsExceptionInfoRequest: Bool = false,
        supportsStepInTargetsRequest: Bool = false,
        supportsGotoTargetsRequest: Bool = false,
        exceptionBreakpointFilters: [DebugExceptionBreakpointFilter] = []
    ) {
        self.negotiated = negotiated
        self.supportsConfigurationDone = supportsConfigurationDone
        self.supportsConditionalBreakpoints = supportsConditionalBreakpoints
        self.supportsHitConditionalBreakpoints = supportsHitConditionalBreakpoints
        self.supportsLogPoints = supportsLogPoints
        self.supportsFunctionBreakpoints = supportsFunctionBreakpoints
        self.supportsDataBreakpoints = supportsDataBreakpoints
        self.supportsExceptionOptions = supportsExceptionOptions
        self.supportsExceptionFilterOptions = supportsExceptionFilterOptions
        self.supportsSetVariable = supportsSetVariable
        self.supportsCancelRequest = supportsCancelRequest
        self.supportsSingleThreadExecutionRequests = supportsSingleThreadExecutionRequests
        self.supportsRestartRequest = supportsRestartRequest
        self.supportsTerminateRequest = supportsTerminateRequest
        self.supportsStepBack = supportsStepBack
        self.supportsExceptionInfoRequest = supportsExceptionInfoRequest
        self.supportsStepInTargetsRequest = supportsStepInTargetsRequest
        self.supportsGotoTargetsRequest = supportsGotoTargetsRequest
        self.exceptionBreakpointFilters = exceptionBreakpointFilters
    }
}

public struct DebugThread: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

public struct DebugStackFrame: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let sourceURL: URL?
    public let line: Int
    public let column: Int
    public let isFiltered: Bool

    public init(
        id: Int,
        name: String,
        sourceURL: URL?,
        line: Int,
        column: Int,
        isFiltered: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.line = line
        self.column = column
        self.isFiltered = isFiltered
    }
}

public struct DebugScope: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let variablesReference: Int
    public let expensive: Bool

    public init(id: Int, name: String, variablesReference: Int, expensive: Bool) {
        self.id = id
        self.name = name
        self.variablesReference = variablesReference
        self.expensive = expensive
    }
}

public struct DebugVariable: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let value: String
    public let type: String?
    public let evaluateName: String?
    public let variablesReference: Int
    public let containerReference: Int?
    public var isExpandable: Bool { variablesReference > 0 }

    public init(
        id: String,
        name: String,
        value: String,
        type: String?,
        evaluateName: String?,
        variablesReference: Int,
        containerReference: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
        self.evaluateName = evaluateName
        self.variablesReference = variablesReference
        self.containerReference = containerReference
    }
}

public enum DebugAdapterEvent: Equatable, Sendable {
    case initialized
    case capabilities(DebugAdapterCapabilities)
    case output(category: String?, output: String)
    case stopped(reason: String, threadID: Int?, description: String?)
    case continued(threadID: Int?)
    case terminated(exitCode: Int?)
    case breakpoint(DebugBreakpoint)
}

public enum DebugExecutionCommand: String, Codable, Equatable, Sendable {
    case continueExecution = "continue"
    case pause, next, stepIn, stepOut, stepBack, goto, restart, terminate
}

@MainActor
public protocol DebugAdapterControllingSession: DebugAdapterSession {
    var capabilities: DebugAdapterCapabilities { get }
    var onStateChange: ((DebugAdapterState) -> Void)? { get set }
    var onEvent: ((DebugAdapterEvent) -> Void)? { get set }
    func launch(_ configuration: DebugLaunchConfiguration) throws
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL)
    func setExceptionBreakpoints(_ breakpoints: [DebugExceptionBreakpoint])
    func setFunctionBreakpoints(_ breakpoints: [DebugFunctionBreakpoint])
    func setDataBreakpoints(_ breakpoints: [DebugDataBreakpoint])
    func requestDataBreakpointInfo(
        name: String,
        variablesReference: Int?,
        frameID: Int?,
        completion: @escaping (Result<DebugDataBreakpointInfo, Error>) -> Void
    )
    func execute(_ command: DebugExecutionCommand, threadID: Int?)
    func execute(_ command: DebugExecutionCommand, threadID: Int?, targetID: Int?)
    func execute(
        _ command: DebugExecutionCommand,
        threadID: Int?,
        targetID: Int?,
        singleThread: Bool
    )
    func requestStepInTargets(
        frameID: Int,
        completion: @escaping (Result<[DebugStepInTarget], Error>) -> Void
    )
    func requestGotoTargets(
        fileURL: URL,
        line: Int,
        column: Int?,
        completion: @escaping (Result<[DebugGotoTarget], Error>) -> Void
    )
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void)
    func requestExceptionInfo(
        threadID: Int,
        completion: @escaping (Result<DebugExceptionInfo, Error>) -> Void
    )
    func requestStackTrace(threadID: Int, completion: @escaping (Result<[DebugStackFrame], Error>) -> Void)
    func requestScopes(frameID: Int, completion: @escaping (Result<[DebugScope], Error>) -> Void)
    func requestVariables(reference: Int, completion: @escaping (Result<[DebugVariable], Error>) -> Void)
    func setVariable(
        variablesReference: Int,
        name: String,
        value: String,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    )
    func evaluate(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void)
    func cancelPendingOperations()
}

public extension DebugAdapterControllingSession {
    var capabilities: DebugAdapterCapabilities { .unknown }
    func setExceptionBreakpoints(_: [DebugExceptionBreakpoint]) {}
    func setFunctionBreakpoints(_: [DebugFunctionBreakpoint]) {}
    func setDataBreakpoints(_: [DebugDataBreakpoint]) {}
    func execute(_ command: DebugExecutionCommand, threadID: Int?, targetID _: Int?) {
        execute(command, threadID: threadID)
    }
    func execute(
        _ command: DebugExecutionCommand,
        threadID: Int?,
        targetID: Int?,
        singleThread _: Bool
    ) {
        execute(command, threadID: threadID, targetID: targetID)
    }
    func requestStepInTargets(
        frameID _: Int,
        completion: @escaping (Result<[DebugStepInTarget], Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("smart step into")))
    }
    func requestGotoTargets(
        fileURL _: URL,
        line _: Int,
        column _: Int?,
        completion: @escaping (Result<[DebugGotoTarget], Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("run to cursor")))
    }
    func requestDataBreakpointInfo(
        name _: String,
        variablesReference _: Int?,
        frameID _: Int?,
        completion: @escaping (Result<DebugDataBreakpointInfo, Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("data breakpoints")))
    }
    func requestExceptionInfo(
        threadID _: Int,
        completion: @escaping (Result<DebugExceptionInfo, Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("exception information")))
    }
    func setVariable(
        variablesReference _: Int,
        name _: String,
        value _: String,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("variable mutation")))
    }
    func cancelPendingOperations() {}
}

public enum DebugAdapterCapabilityError: LocalizedError, Sendable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(feature):
            "The active debug adapter does not support \(feature)."
        }
    }
}
