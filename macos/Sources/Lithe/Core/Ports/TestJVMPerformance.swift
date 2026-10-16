import Foundation

struct TestJVMProcess: Equatable, Hashable, Sendable, Identifiable {
    let processID: Int32
    let javaExecutable: URL
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    var id: String { "\(processID):\(startedSeconds):\(startedMicroseconds)" }
    var target: DebugPerformanceTarget { DebugPerformanceTarget(processID: processID, javaExecutable: javaExecutable) }
}

struct TestJVMRecording: Equatable, Sendable {
    let id: UUID
    let process: TestJVMProcess
    let fileURL: URL
    let startedAt: Date
    var name: String { "lithe-\(id.uuidString)" }
}

/// JDK tools own recording and report semantics; the native host owns processes
/// and temporary files. No JFR binary parser or JVM agent lives in the UI.
protocol TestJVMPerformanceProviding: Sendable {
    func processes(rootProcessID: Int32) -> AsyncThrowingStream<[TestJVMProcess], Error>
    func startRecording(_ process: TestJVMProcess) async throws -> TestJVMRecording
    func stopRecording(_ recording: TestJVMRecording) async throws
    func report(_ recording: TestJVMRecording) async throws -> String
    func discard(_ recording: TestJVMRecording) async
}
