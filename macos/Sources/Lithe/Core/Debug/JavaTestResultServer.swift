import Foundation

/// Platform port for the short-lived loopback server required by Java test runners.
@MainActor
protocol JavaTestResultServing: AnyObject {
    func start() async throws -> UInt16
    func stop()
}
