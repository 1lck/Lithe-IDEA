import Foundation

/// An injected, thread-safe ingress. Implementations enqueue without waiting for
/// encoding, disk I/O or subscribers; overload is reported by the store.
public protocol LogSink: Sendable {
    func emit(_ event: any LogEvent)
    func emit(_ record: CoreLogRecord)
}

/// One operation's trusted channel identities and correlation. Supply `segments`
/// to generated event initializers; the catalog remains the routing authority.
public struct LogScope: LogSink, Sendable {
    public let segments: [LogSegment]
    public let operationID: String
    private let sink: any LogSink

    public init(sink: any LogSink, segments: [LogSegment] = [], operationID: String = UUID().uuidString) {
        self.sink = sink
        self.segments = segments
        self.operationID = operationID
    }

    public func emit(_ event: any LogEvent) { forward(event) }

    public func emit(_ record: CoreLogRecord) { sink.emit(record) }

    private func forward<E: LogEvent>(_ event: E) {
        sink.emit(ScopedLogEvent(value: event, operationID: event.operationID ?? operationID))
    }
}

private struct ScopedLogEvent<E: LogEvent>: LogEvent {
    let value: E
    let operationID: String?
    static var id: String { E.id }
    static var level: LogLevel { E.level }
    static var messageTemplate: String { E.messageTemplate }
    static var ratePerMinute: Int { E.ratePerMinute }
    static var owner: String { E.owner }
    static var debugOnly: Bool { E.debugOnly }
    var channel: LogChannel { value.channel }
    var fields: [String: LogFieldValue] { value.fields }
}
