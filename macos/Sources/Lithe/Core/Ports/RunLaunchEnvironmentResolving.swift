import Foundation

/// One platform-discovered directory and its deterministic search order.
struct RunSearchPathCandidate: Encodable, Sendable {
    let priority: UInt32
    let id: String
    let path: String
}

/// Platform discovery supplies homes; Core owns precedence for every launch step.
protocol RunLaunchEnvironmentResolving {
    func resolveSearchPath(existing: [String], candidates: [RunSearchPathCandidate]) throws -> [String]

    func resolveLaunchEnvironment(
        toolchain: String?,
        selectedHome: String?,
        inherited: [String: String],
        overrides: [String: String]
    ) throws -> [String: String]
}
