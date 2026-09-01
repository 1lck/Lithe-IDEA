import os

enum LitheSignpost {
    private static let signposter = OSSignposter(
        subsystem: "com.openres.Lithe",
        category: "Rendering"
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
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
