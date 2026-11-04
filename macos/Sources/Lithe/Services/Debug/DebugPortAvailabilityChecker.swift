import Foundation

/// Answers whether a local service port can be claimed before a debug launch.
/// The probing mechanism belongs to a platform adapter; application code only
/// consumes this small synchronous capability.
@MainActor
protocol DebugPortAvailabilityChecking: AnyObject {
    func isPortAvailable(_ port: Int) -> Bool
    func unusedLoopbackPort() throws -> UInt16
    func waitForLoopbackListener(_ port: UInt16, processID: @escaping @MainActor () -> Int32?, isCurrent: @escaping @MainActor () -> Bool) async throws
}

extension DebugPortAvailabilityChecking {
    func unusedLoopbackPort() throws -> UInt16 {
        throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable
    }
    func waitForLoopbackListener(_ port: UInt16, processID: @escaping @MainActor () -> Int32?, isCurrent: @escaping @MainActor () -> Bool) async throws {
        throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable
    }
}

@MainActor
final class AlwaysAvailableDebugPortChecker: DebugPortAvailabilityChecking {
    func isPortAvailable(_: Int) -> Bool { true }
}
