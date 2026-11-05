import Foundation
import LitheModuleAPI

final class TypedLogRecorder: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var coreValues: [CoreLogRecord] = []
    var coreRecords: [CoreLogRecord] { lock.withLock { coreValues } }
    func emit(_ record: CoreLogRecord) { lock.withLock { coreValues.append(record) } }
    private var values: [any LogEvent] = []
    var events: [any LogEvent] { lock.withLock { values } }
    func emit(_ event: any LogEvent) { lock.withLock { values.append(event) } }
}
