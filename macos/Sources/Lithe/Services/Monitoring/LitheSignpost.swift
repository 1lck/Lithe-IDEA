import LitheModuleAPI
import Foundation
import os

enum LitheSignpost {
    struct State {
        let osState: OSSignpostIntervalState
        let startedAt: UInt64
        let name: String
        let logSink: (any LogSink)?
    }

    private static let signposter = OSSignposter(
        subsystem: "com.openres.Lithe",
        category: "Rendering"
    )
    private static let baselineEnabled =
        ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1"
    static let settingsLatencyTracingEnabled =
        ProcessInfo.processInfo.environment["LITHE_SETTINGS_LATENCY_TRACE"] == "1"

    /// Opt-in native timestamps, independent of the external AX observer and
    /// of the baseline mode that disables the normal frame-rate monitor.
    static func settingsLatencyEvent(
        _ phase: String, category: String, eventID: Int64,
        input: UInt64, received: UInt64, selected: UInt64, logSink: (any LogSink)? = nil
    ) {
        guard settingsLatencyTracingEnabled else { return }
        let time = DispatchTime.now().uptimeNanoseconds
        logSink?.emit(PerfSettingsLatencyMeasured(category: category, eventId: eventID, inputNs: Int64(clamping: input), phase: phase, receivedNs: Int64(clamping: received), selectedNs: Int64(clamping: selected), timeNs: Int64(clamping: time)))
        (logSink as? any PerformanceMarkerWriting)?.writePerformanceMarker("LITHE_SETTINGS_LATENCY phase=\(phase) category=\(category) event_id=\(eventID) time_ns=\(time) input_ns=\(input) received_ns=\(received) selected_ns=\(selected)\n")
    }

    static func begin(_ name: StaticString, logSink: (any LogSink)? = nil) -> State {
        State(
            osState: signposter.beginInterval(name),
            startedAt: DispatchTime.now().uptimeNanoseconds,
            name: "\(name)", logSink: logSink
        )
    }

    static func end(_ name: StaticString, _ state: State) {
        signposter.endInterval(name, state.osState)
        guard baselineEnabled else { return }

        let durationNanoseconds = DispatchTime.now().uptimeNanoseconds - state.startedAt
        let durationMilliseconds = Double(durationNanoseconds) / 1_000_000
        // Baseline runs need a portable fallback because Instruments may omit
        // application signposts even when the OS signpost API is active.
        let line = String(
            format: "LITHE_PERF_SIGNPOST name=%@ duration_ms=%.3f\n",
            state.name,
            durationMilliseconds
        )
        state.logSink?.emit(PerfAppSignpostMeasured(duration: .nanoseconds(Int64(clamping: durationNanoseconds)), name: state.name))
        (state.logSink as? any PerformanceMarkerWriting)?.writePerformanceMarker(line)
    }

    #if DEBUG
    private static var bodyCounts: [String: Int] = [:]

    static func bodyEvaluated(_ view: StaticString) {
        bodyCounts["\(view)", default: 0] += 1
    }
    #else
    @inlinable @inline(__always)
    static func bodyEvaluated(_ view: StaticString) {}
    #endif
}
