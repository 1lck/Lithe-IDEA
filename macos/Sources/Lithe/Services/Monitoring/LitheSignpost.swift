import Foundation
import os

enum LitheSignpost {
    struct State {
        let osState: OSSignpostIntervalState
        let startedAt: UInt64
        let name: String
    }

    private static let signposter = OSSignposter(
        subsystem: "com.openres.Lithe",
        category: "Rendering"
    )
    private static let baselineEnabled =
        ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1"
    private static var baselineOutput: ((String) -> Void)?

    static func configureBaselineOutput(_ output: @escaping (String) -> Void) {
        baselineOutput = output
    }

    static func begin(_ name: StaticString) -> State {
        State(
            osState: signposter.beginInterval(name),
            startedAt: DispatchTime.now().uptimeNanoseconds,
            name: "\(name)"
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
        baselineOutput?(line)
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
