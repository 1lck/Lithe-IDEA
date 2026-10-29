import Foundation

/// Platform discovery supplies homes; Core owns precedence for every launch step.
protocol RunLaunchEnvironmentResolving {
    func resolveLaunchEnvironment(
        toolchain: String?,
        selectedHome: String?,
        inherited: [String: String],
        overrides: [String: String]
    ) throws -> [String: String]
}
