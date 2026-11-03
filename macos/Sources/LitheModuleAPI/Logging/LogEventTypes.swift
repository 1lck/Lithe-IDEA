import Foundation

/// Severity vocabulary shared by the generated catalog and Rust metadata.
public enum LogLevel: String, Sendable, CaseIterable {
    case debug, info, warn, error
}

/// An opaque identifier, never an arbitrary path or display name.
public struct LogSegment: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard (1...64).contains(bytes.count),
              bytes[0].isASCIILowercaseOrDigit,
              bytes.allSatisfy({ $0.isASCIILowercaseOrDigit || [46, 95, 45].contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
}

private extension UInt8 {
    var isASCIILowercaseOrDigit: Bool { (97...122).contains(self) || (48...57).contains(self) }
}

/// A fixed root with already validated identifier segments.
public struct LogChannel: Hashable, Sendable {
    public enum Root: String, Sendable, CaseIterable {
        case app, editor, perf, lsp, vcs, run, debug, terminal, remote, agent, update, plugins
    }

    public let root: Root
    public let segments: [LogSegment]

    public init(_ root: Root, segments: [LogSegment] = []) {
        self.root = root
        self.segments = segments
    }

    public var rawValue: String { ([root.rawValue] + segments.map(\.rawValue)).joined(separator: "/") }
}

/// Logical values only. The Core persistence boundary owns redaction, limits,
/// duration `_ms` encoding and structured error expansion; these values are not safe disk text.
public enum LogFieldValue: Sendable {
    case int(Int64)
    case bool(Bool)
    case duration(Duration)
    case bytes(UInt64)
    case id(LogSegment)
    case token(String)
    case version(String)
    case path(URL)
    case error(any Error)
    case text(String)
}

/// A source-owned machine failure with no upstream prose or command output.
/// The persistence adapter preserves string codes instead of inventing an NSError number.
public struct LogFailure: Error, Sendable {
    public let domain: String
    public let code: String
    public init(domain: String, code: String) { self.domain = domain; self.code = code }
}

/// Typed event input; it performs no I/O and does not change existing logging.
public protocol LogEvent: Sendable {
    static var id: String { get }
    static var level: LogLevel { get }
    static var messageTemplate: String { get }
    static var ratePerMinute: Int { get }
    static var owner: String { get }
    static var debugOnly: Bool { get }
    var channel: LogChannel { get }
    var fields: [String: LogFieldValue] { get }
    var operationID: String? { get }
}

/// Inject a monotonic clock without sleeps; values are offsets, never wall time.
public struct LogSpanClock: Sendable {
    private let read: @Sendable () -> Duration
    public init(now: @escaping @Sendable () -> Duration) { read = now }
    public func now() -> Duration { read() }
    public static var continuous: Self {
        let origin = ContinuousClock.now
        return Self { origin.duration(to: .now) }
    }
}

/// Value-owned span lifetime. Keep one owner; the first terminal action wins.
public struct LogSpanState: Sendable {
    public let operationID: String
    private let clock: LogSpanClock
    private let started: Duration
    private var ended = false

    public init(operationID: String, clock: LogSpanClock) {
        self.operationID = operationID
        self.clock = clock
        started = clock.now()
    }

    public mutating func end() -> Duration? {
        guard !ended else { return nil }
        ended = true
        return max(.zero, clock.now() - started)
    }
}
