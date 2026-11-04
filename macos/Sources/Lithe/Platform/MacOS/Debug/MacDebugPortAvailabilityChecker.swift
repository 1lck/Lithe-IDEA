import Darwin
import Foundation
import LitheModuleAPI

/// Probes loopback TCP ports without creating a long-lived listener.
@MainActor
final class MacDebugPortAvailabilityChecker: DebugPortAvailabilityChecking {
    func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let located = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) == 0 }
        }
        guard bound, located, address.sin_port != 0 else { throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }

    /// A bind probe does not connect to or resume a suspended JDWP VM. The
    /// operation guard also ends the wait when its owning process exits.
    func waitForLoopbackListener(_ port: UInt16, processID: @escaping @MainActor () -> Int32?, isCurrent: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while clock.now < deadline {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if !isPortAvailable(Int(port)), let pid = processID(), pid > 0 {
                let owned = await Task.detached(priority: .utility) {
                    let snapshot = MacProcessTable.snapshot()
                    let processes = [pid] + MacProcessTable.descendants(of: pid, in: snapshot).map(\.processID)
                    return processes.contains { MacProcessTable.listeningTCPPorts(processID: $0).contains(Int(port)) }
                }.value
                if owned { try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }; return }
            }
            guard isCurrent() else { throw CancellationError() }
            try await clock.sleep(for: .milliseconds(100))
        }
        throw RunConfigurationOperationFailure(message: L10n.string("The framework did not open its JVM debug port before the deadline. Check the Run output."))
    }

    func isPortAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
            }
        }
    }
}
