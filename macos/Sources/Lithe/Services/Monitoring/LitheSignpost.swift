import os

enum LitheSignpost {
    private static let signposter = OSSignposter(
        subsystem: "com.openres.Lithe",
        category: "Rendering"
    )

    static func begin(_ name: StaticString) -> OSSignposter.IntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignposter.IntervalState) {
        signposter.endInterval(name, state)
    }

    #if DEBUG
    private static var bodyCounts: [StaticString: Int] = [:]

    static func bodyEvaluated(_ view: StaticString) {
        bodyCounts[view, default: 0] += 1
    }
    #else
    @inlinable @inline(__always)
    static func bodyEvaluated(_ view: StaticString) {}
    #endif
}
