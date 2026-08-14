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

public extension DebugAdapterSession {
    var state: DebugAdapterState { isRunning ? .running : .idle }
}

public enum DebugAdapterState: String, Equatable, Sendable {
    case idle, initializing, ready, launching, running, paused, terminated, failed
}

public enum DebugRequestKind: String, Equatable, Sendable {
    case launch, attach
}

public struct DebugLaunchConfiguration: Equatable, Sendable {
    public let name: String
    public let request: DebugRequestKind
    public let arguments: [String: ToolingJSONValue]

    public init(name: String, request: DebugRequestKind, arguments: [String: ToolingJSONValue]) {
        self.name = name
        self.request = request
        self.arguments = arguments
    }
}

public struct DebugSourceBreakpoint: Hashable, Sendable {
    public let line: Int
    public let column: Int?
    public let condition: String?

    public init(line: Int, column: Int? = nil, condition: String? = nil) {
        self.line = line
        self.column = column
        self.condition = condition
    }
}

public struct DebugBreakpoint: Identifiable, Equatable, Sendable {
    public let id: Int
    public let verified: Bool
    public let message: String?
    public let sourceURL: URL?
    public let line: Int?
    public let column: Int?

    public init(id: Int, verified: Bool, message: String?, sourceURL: URL?, line: Int?, column: Int?) {
        self.id = id
        self.verified = verified
        self.message = message
        self.sourceURL = sourceURL
        self.line = line
        self.column = column
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

    public init(id: Int, name: String, sourceURL: URL?, line: Int, column: Int) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.line = line
        self.column = column
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
    public var isExpandable: Bool { variablesReference > 0 }

    public init(
        id: String,
        name: String,
        value: String,
        type: String?,
        evaluateName: String?,
        variablesReference: Int
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
        self.evaluateName = evaluateName
        self.variablesReference = variablesReference
    }
}

public enum DebugAdapterEvent: Equatable, Sendable {
    case initialized
    case output(category: String?, output: String)
    case stopped(reason: String, threadID: Int?, description: String?)
    case continued(threadID: Int?)
    case terminated(exitCode: Int?)
    case breakpoint(DebugBreakpoint)
}

public enum DebugExecutionCommand: String, Equatable, Sendable {
    case continueExecution = "continue"
    case pause, next, stepIn, stepOut
}

@MainActor
public protocol DebugAdapterControllingSession: DebugAdapterSession {
    var onStateChange: ((DebugAdapterState) -> Void)? { get set }
    var onEvent: ((DebugAdapterEvent) -> Void)? { get set }
    func launch(_ configuration: DebugLaunchConfiguration) throws
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL)
    func execute(_ command: DebugExecutionCommand, threadID: Int?)
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void)
    func requestStackTrace(threadID: Int, completion: @escaping (Result<[DebugStackFrame], Error>) -> Void)
    func requestScopes(frameID: Int, completion: @escaping (Result<[DebugScope], Error>) -> Void)
    func requestVariables(reference: Int, completion: @escaping (Result<[DebugVariable], Error>) -> Void)
    func evaluate(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void)
}
