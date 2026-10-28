import LitheModuleAPI
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

/// Optional bounded best-effort flush for the final DAP disconnect frame.
/// This ends the transport, never the external server; `stop` still aborts now.
@MainActor
public protocol DebugAdapterDrainingTransport: DebugAdapterTransport {
    func finishSendingAndStop()
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

/// IDE-to-adapter DAP endpoint, never the adapter-to-debuggee attach target.
/// Core validates it before the platform asks consent or opens a connection.
public struct DebugAdapterEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct DebugLaunchConfiguration: Codable, Equatable, Sendable {
    public let name: String
    public let request: DebugRequestKind
    public let arguments: [String: ToolingJSONValue]
    public let steppingFilters: DebugSteppingFilters?
    /// An already running DAP server; absent means the provider's normal transport.
    public let adapterEndpoint: DebugAdapterEndpoint?

    public init(
        name: String,
        request: DebugRequestKind,
        arguments: [String: ToolingJSONValue],
        steppingFilters: DebugSteppingFilters? = nil,
        adapterEndpoint: DebugAdapterEndpoint? = nil
    ) {
        self.name = name
        self.request = request
        self.arguments = arguments
        self.steppingFilters = steppingFilters
        self.adapterEndpoint = adapterEndpoint
    }

    public func applying(steppingFilters: DebugSteppingFilters) -> Self {
        Self(
            name: name,
            request: request,
            arguments: arguments,
            steppingFilters: steppingFilters,
            adapterEndpoint: adapterEndpoint
        )
    }
}

public enum DebugRunInTerminalKind: String, Codable, Equatable, Sendable {
    case integrated, external
}

public struct DebugRunInTerminalEnvironmentVariable: Codable, Equatable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// A normalized DAP reverse request. `args.first` is the executable and the
/// remaining values stay as an argument array unless shell interpretation was
/// explicitly requested by the adapter.
public struct DebugRunInTerminalRequest: Codable, Equatable, Sendable {
    public let kind: DebugRunInTerminalKind
    public let title: String?
    public let cwd: String
    public let args: [String]
    public let environment: [DebugRunInTerminalEnvironmentVariable]
    public let argsCanBeInterpretedByShell: Bool

    public init(
        kind: DebugRunInTerminalKind,
        title: String?,
        cwd: String,
        args: [String],
        environment: [DebugRunInTerminalEnvironmentVariable],
        argsCanBeInterpretedByShell: Bool
    ) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.args = args
        self.environment = environment
        self.argsCanBeInterpretedByShell = argsCanBeInterpretedByShell
    }
}

public struct DebugRunInTerminalResponse: Equatable, Sendable {
    public let processID: Int?
    public let shellProcessID: Int?

    public init(processID: Int?, shellProcessID: Int? = nil) {
        self.processID = processID
        self.shellProcessID = shellProcessID
    }
}

public typealias DebugRunInTerminalCompletion = (
    Result<DebugRunInTerminalResponse, Error>
) -> Void
public typealias DebugRunInTerminalRequestHandler = (
    DebugRunInTerminalRequest,
    @escaping DebugRunInTerminalCompletion
) -> Void

/// Child debug session the adapter asks the host to open through DAP `startDebugging`.
/// `configuration` excludes the `request` key and keeps adapter-specific fields verbatim.
public struct DebugStartDebuggingRequest: Decodable, Equatable, Sendable {
    public let request: DebugRequestKind
    public let configuration: [String: ToolingJSONValue]

    public init(request: DebugRequestKind, configuration: [String: ToolingJSONValue]) {
        self.request = request
        self.configuration = configuration
    }
}

public typealias DebugStartDebuggingCompletion = (Result<Void, Error>) -> Void
public typealias DebugStartDebuggingRequestHandler = (
    DebugStartDebuggingRequest,
    @escaping DebugStartDebuggingCompletion
) -> Void

/// Optional reverse-request surface for sessions whose host can open child sessions.
/// Core only advertises `startDebugging` support while a handler is installed.
@MainActor
public protocol DebugAdapterStartDebuggingSession: AnyObject {
    var onStartDebuggingRequest: DebugStartDebuggingRequestHandler? { get set }
}

/// Lets the host link a session to its parent in the shared Core session tree.
/// `parentCoreSessionID` must be set before `start`; Core rejects an unknown parent.
@MainActor
public protocol DebugAdapterChildSessionLinking: AnyObject {
    var coreSessionID: String { get }
    var parentCoreSessionID: String? { get set }
}

/// Optional reverse-request surface implemented only by sessions whose native
/// host can create an integrated terminal before DAP initialization begins.
@MainActor
public protocol DebugAdapterRunInTerminalSession: AnyObject {
    var onRunInTerminalRequest: DebugRunInTerminalRequestHandler? { get set }
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
public struct JavaDebugLaunchTarget: Hashable, Sendable {
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

/// Java test runner family reported by the JDT LS Java Test extension.
public enum JavaTestDebugFramework: String, Codable, Equatable, Sendable {
    case junit
    case testng
}

/// JDT LS-owned metadata required to launch one Java test selection through DAP.
public struct JavaTestDebugLaunchTarget: Equatable, Sendable {
    public let fileURL: URL
    public let name: String
    public let framework: JavaTestDebugFramework
    public let workingDirectory: String
    public let mainClass: String
    public let projectName: String?
    public let classPaths: [String]
    public let modulePaths: [String]
    public let vmArguments: [String]
    public let programArguments: [String]
    public let testNGRunnerPath: String?
    public let testNGTestNames: [String]

    public init(
        fileURL: URL,
        name: String,
        framework: JavaTestDebugFramework,
        workingDirectory: String,
        mainClass: String,
        projectName: String?,
        classPaths: [String],
        modulePaths: [String],
        vmArguments: [String],
        programArguments: [String],
        testNGRunnerPath: String? = nil,
        testNGTestNames: [String] = []
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.name = name
        self.framework = framework
        self.workingDirectory = workingDirectory
        self.mainClass = mainClass
        self.projectName = projectName
        self.classPaths = classPaths
        self.modulePaths = modulePaths
        self.vmArguments = vmArguments
        self.programArguments = programArguments
        self.testNGRunnerPath = testNGRunnerPath
        self.testNGTestNames = testNGTestNames
    }
}

/// Resolves a Java test selection through the active language-service project model.
@MainActor
public protocol JavaTestDebugLaunchTargetResolving: AnyObject {
    func resolveJavaTestDebugLaunchTarget(
        fileURL: URL,
        testIdentifier: String?,
        rootURL: URL
    ) async throws -> JavaTestDebugLaunchTarget
}

/// One exact editor replacement using zero-based, document-relative UTF-16 offsets.
public struct DebugSourceEdit: Codable, Equatable, Sendable {
    public let startUTF16Offset: Int
    public let endUTF16Offset: Int
    public let replacement: String

    public init(startUTF16Offset: Int, endUTF16Offset: Int, replacement: String) {
        self.startUTF16Offset = startUTF16Offset
        self.endUTF16Offset = endUTF16Offset
        self.replacement = replacement
    }

    private enum CodingKeys: String, CodingKey {
        case startUTF16Offset = "startUtf16Offset"
        case endUTF16Offset = "endUtf16Offset"
        case replacement
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
    /// Address of an instruction breakpoint; opaque, never parsed by the host.
    public let instructionReference: String?
    public let sourceURL: URL?
    public let requestedLine: Int?
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
        dataID: String? = nil,
        requestedLine: Int? = nil,
        instructionReference: String? = nil
    ) {
        self.id = id
        self.verified = verified
        self.message = message
        self.functionName = functionName
        self.dataID = dataID
        self.instructionReference = instructionReference
        self.sourceURL = sourceURL
        self.requestedLine = requestedLine
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

/// A breakpoint on one machine instruction. `instructionReference` is the opaque
/// address string the adapter reported; 64-bit addresses are never parsed or added to.
public struct DebugInstructionBreakpoint: Codable, Hashable, Sendable {
    public let instructionReference: String
    public let offset: Int?
    public let enabled: Bool
    public let condition: String?
    public let hitCondition: String?

    public init(
        instructionReference: String,
        offset: Int? = nil,
        enabled: Bool = true,
        condition: String? = nil,
        hitCondition: String? = nil
    ) {
        self.instructionReference = instructionReference
        self.offset = offset
        self.enabled = enabled
        self.condition = condition
        self.hitCondition = hitCondition
    }
}

/// How far one step moves, in the DAP `SteppingGranularity` vocabulary.
public enum DebugSteppingGranularity: String, Codable, Equatable, Sendable {
    case statement, line, instruction
}

/// One machine instruction. `address` and `instructionBytes` stay adapter-formatted
/// strings so they are shown exactly as reported.
public struct DebugDisassembledInstruction: Identifiable, Equatable, Sendable {
    public let address: String
    public let instructionBytes: String?
    public let instruction: String
    /// Symbol the instruction belongs to; reported only on the first instruction of it.
    public let symbol: String?
    public let sourceURL: URL?
    public let line: Int?

    public var id: String { address }

    public init(
        address: String,
        instructionBytes: String?,
        instruction: String,
        symbol: String? = nil,
        sourceURL: URL? = nil,
        line: Int? = nil
    ) {
        self.address = address
        self.instructionBytes = instructionBytes
        self.instruction = instruction
        self.symbol = symbol
        self.sourceURL = sourceURL
        self.line = line
    }
}

/// Raw debuggee bytes returned by a read-only memory request.
public struct DebugMemoryRead: Equatable, Sendable {
    public let address: String
    public let unreadableBytes: Int
    public let data: Data

    public init(address: String, unreadableBytes: Int, data: Data) {
        self.address = address
        self.unreadableBytes = unreadableBytes
        self.data = data
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

/// One Debug Console proposal. `start`/`length` select the typed text it replaces
/// (zero-based UTF-16 units); adapters that send no range expect the client to
/// replace the word ending at the caret.
public struct DebugCompletionItem: Identifiable, Equatable, Sendable {
    public let label: String
    public let text: String
    public let detail: String?
    public let kind: String?
    public let start: Int?
    public let length: Int?

    public var id: String { "\(text)\u{0}\(label)" }

    public init(
        label: String,
        text: String,
        detail: String? = nil,
        kind: String? = nil,
        start: Int? = nil,
        length: Int? = nil
    ) {
        self.label = label
        self.text = text
        self.detail = detail
        self.kind = kind
        self.start = start
        self.length = length
    }
}

/// A debugger command a plugin declares for Debug Console completion, for adapters
/// that cannot propose commands themselves. `detail` is the plugin's own text.
public struct DebugConsoleCommand: Equatable, Sendable {
    public let name: String
    public let detail: String?

    public init(name: String, detail: String? = nil) {
        self.name = name
        self.detail = detail
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
    public let supportsCompletionsRequest: Bool
    public let supportsDisassembleRequest: Bool
    public let supportsSteppingGranularity: Bool
    public let supportsInstructionBreakpoints: Bool
    public let supportsReadMemoryRequest: Bool
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
        supportsCompletionsRequest: Bool = false,
        supportsDisassembleRequest: Bool = false,
        supportsSteppingGranularity: Bool = false,
        supportsInstructionBreakpoints: Bool = false,
        supportsReadMemoryRequest: Bool = false,
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
        self.supportsCompletionsRequest = supportsCompletionsRequest
        self.supportsDisassembleRequest = supportsDisassembleRequest
        self.supportsSteppingGranularity = supportsSteppingGranularity
        self.supportsInstructionBreakpoints = supportsInstructionBreakpoints
        self.supportsReadMemoryRequest = supportsReadMemoryRequest
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
    /// Address of the frame's current instruction. A frame without debug info has no
    /// file and `line` 0, so the disassembly view anchors on this instead.
    public let instructionPointerReference: String?

    /// True when the frame has no file the editor could open. Adapters such as
    /// lldb-dap still report a line for code without debug information (they serve
    /// the disassembly as a synthetic source), so the line alone does not tell.
    public var isSourceless: Bool { sourceURL == nil }

    public init(
        id: Int,
        name: String,
        sourceURL: URL?,
        line: Int,
        column: Int,
        isFiltered: Bool = false,
        instructionPointerReference: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.line = line
        self.column = column
        self.isFiltered = isFiltered
        self.instructionPointerReference = instructionPointerReference
    }
}

public struct DebugScope: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let variablesReference: Int
    public let expensive: Bool
    public let namedVariables: Int
    public let indexedVariables: Int
    /// DAP `presentationHint` (`arguments`, `locals`, `registers`), or nil.
    public let presentationHint: String?

    public var isRegisters: Bool { presentationHint == "registers" }

    public init(
        id: Int,
        name: String,
        variablesReference: Int,
        expensive: Bool,
        namedVariables: Int = 0,
        indexedVariables: Int = 0,
        presentationHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.variablesReference = variablesReference
        self.expensive = expensive
        self.namedVariables = max(0, namedVariables)
        self.indexedVariables = max(0, indexedVariables)
        self.presentationHint = presentationHint
    }
}

public enum DebugVariableFilter: String, Codable, Equatable, Sendable {
    case named, indexed
}

public struct DebugVariable: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let value: String
    public let type: String?
    public let evaluateName: String?
    public let variablesReference: Int
    public let containerReference: Int?
    public let namedVariables: Int
    public let indexedVariables: Int
    public var isExpandable: Bool { variablesReference > 0 }

    public init(
        id: String,
        name: String,
        value: String,
        type: String?,
        evaluateName: String?,
        variablesReference: Int,
        containerReference: Int? = nil,
        namedVariables: Int = 0,
        indexedVariables: Int = 0
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
        self.evaluateName = evaluateName
        self.variablesReference = variablesReference
        self.containerReference = containerReference
        self.namedVariables = max(0, namedVariables)
        self.indexedVariables = max(0, indexedVariables)
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
    func setInstructionBreakpoints(_ breakpoints: [DebugInstructionBreakpoint])
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
    /// Steps by `granularity`; adapters without `supportsSteppingGranularity` fall back
    /// to their default step.
    func execute(
        _ command: DebugExecutionCommand,
        threadID: Int?,
        granularity: DebugSteppingGranularity
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
    func redefineClasses(_ completion: @escaping (Result<[String], Error>) -> Void)
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void)
    func requestExceptionInfo(
        threadID: Int,
        completion: @escaping (Result<DebugExceptionInfo, Error>) -> Void
    )
    /// Instructions around `memoryReference`; `instructionOffset` may be negative to ask
    /// for instructions before it. Valid only while the thread stays stopped.
    func requestDisassembly(
        memoryReference: String,
        instructionOffset: Int,
        instructionCount: Int,
        completion: @escaping (Result<[DebugDisassembledInstruction], Error>) -> Void
    )
    /// Reads `count` bytes at `memoryReference` plus `offset`. Read-only.
    func requestReadMemory(
        memoryReference: String,
        offset: Int,
        count: Int,
        completion: @escaping (Result<DebugMemoryRead, Error>) -> Void
    )
    func requestStackTrace(threadID: Int, completion: @escaping (Result<[DebugStackFrame], Error>) -> Void)
    func requestScopes(frameID: Int, completion: @escaping (Result<[DebugScope], Error>) -> Void)
    func requestVariables(reference: Int, completion: @escaping (Result<[DebugVariable], Error>) -> Void)
    func requestVariables(
        reference: Int,
        filter: DebugVariableFilter?,
        start: Int?,
        count: Int?,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    )
    func setVariable(
        variablesReference: Int,
        name: String,
        value: String,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    )
    func evaluate(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void)
    /// Runs console input in the DAP `repl` context, which adapters such as lldb-dap
    /// also use for their own debugger commands. Adapters without a distinct repl
    /// treat it as a plain evaluation.
    func evaluateInConsole(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void)
    /// Asks the adapter for Debug Console proposals. `column` is the caret as a
    /// UTF-16 offset from 0 into `text` and defaults to its end.
    func requestCompletions(
        _ text: String,
        column: Int?,
        frameID: Int?,
        completion: @escaping (Result<[DebugCompletionItem], Error>) -> Void
    )
    /// Commands the adapter's plugin declared for completion; empty for other adapters.
    var consoleCommands: [DebugConsoleCommand] { get }
    /// Text the adapter's console reads as "a debugger command follows"; nil when the
    /// plugin declared none.
    var consoleCommandPrefix: String? { get }
    func cancelPendingOperations()
}

public extension DebugAdapterControllingSession {
    var consoleCommands: [DebugConsoleCommand] { [] }
    var consoleCommandPrefix: String? { nil }
    func evaluateInConsole(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {
        evaluate(expression, frameID: frameID, completion: completion)
    }
    func redefineClasses(_ completion: @escaping (Result<[String], Error>) -> Void) {
        completion(.failure(NSError(domain: "Lithe.Debug", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.string("This adapter does not support hot code replacement.")])))
    }
    var capabilities: DebugAdapterCapabilities { .unknown }
    func setExceptionBreakpoints(_: [DebugExceptionBreakpoint]) {}
    func setFunctionBreakpoints(_: [DebugFunctionBreakpoint]) {}
    func setDataBreakpoints(_: [DebugDataBreakpoint]) {}
    func setInstructionBreakpoints(_: [DebugInstructionBreakpoint]) {}
    func execute(
        _ command: DebugExecutionCommand,
        threadID: Int?,
        granularity _: DebugSteppingGranularity
    ) {
        execute(command, threadID: threadID)
    }
    func requestDisassembly(
        memoryReference _: String,
        instructionOffset _: Int,
        instructionCount _: Int,
        completion: @escaping (Result<[DebugDisassembledInstruction], Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("disassembly")))
    }
    func requestReadMemory(
        memoryReference _: String,
        offset _: Int,
        count _: Int,
        completion: @escaping (Result<DebugMemoryRead, Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("memory reading")))
    }
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
    func requestCompletions(
        _: String,
        column _: Int?,
        frameID _: Int?,
        completion: @escaping (Result<[DebugCompletionItem], Error>) -> Void
    ) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("console completion")))
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
    func requestVariables(
        reference: Int,
        filter _: DebugVariableFilter?,
        start _: Int?,
        count _: Int?,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) {
        requestVariables(reference: reference, completion: completion)
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
            L10n.string("The active debug adapter does not support \(feature).")
        }
    }
}
