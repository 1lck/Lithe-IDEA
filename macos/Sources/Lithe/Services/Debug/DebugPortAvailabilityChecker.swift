import Foundation

/// Answers whether a local service port can be claimed before a debug launch.
/// The probing mechanism belongs to a platform adapter; application code only
/// consumes this small synchronous capability.
@MainActor
protocol DebugPortAvailabilityChecking: AnyObject {
    func isPortAvailable(_ port: Int) -> Bool
}

@MainActor
final class AlwaysAvailableDebugPortChecker: DebugPortAvailabilityChecking {
    func isPortAvailable(_: Int) -> Bool { true }
}
