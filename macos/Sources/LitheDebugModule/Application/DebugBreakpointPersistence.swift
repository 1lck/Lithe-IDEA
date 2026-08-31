import Foundation

public struct PersistedDebugBreakpoint: Codable, Equatable, Sendable {
    public let relativePath: String
    public let line: Int
    public let column: Int?
    public let enabled: Bool
    public let condition: String?
    public let hitCondition: String?
    public let logMessage: String?

    public init(
        relativePath: String,
        line: Int,
        column: Int? = nil,
        enabled: Bool = true,
        condition: String? = nil,
        hitCondition: String? = nil,
        logMessage: String? = nil
    ) {
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.enabled = enabled
        self.condition = condition
        self.hitCondition = hitCondition
        self.logMessage = logMessage
    }
}

public struct DebugBreakpointSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let areBreakpointsMuted: Bool
    public let breakpoints: [PersistedDebugBreakpoint]

    public init(
        version: Int = Self.currentVersion,
        areBreakpointsMuted: Bool = false,
        breakpoints: [PersistedDebugBreakpoint]
    ) {
        self.version = version
        self.areBreakpointsMuted = areBreakpointsMuted
        self.breakpoints = breakpoints
    }
}

public protocol DebugBreakpointPersisting: Sendable {
    func loadBreakpoints(for workspaceURL: URL) throws -> DebugBreakpointSnapshot?
    func saveBreakpoints(_ snapshot: DebugBreakpointSnapshot, for workspaceURL: URL) throws
}
