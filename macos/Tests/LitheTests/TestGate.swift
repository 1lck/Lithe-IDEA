import Foundation

/// One-shot coordination primitive for test doubles that implement synchronous
/// protocols. The deadline prevents a failed test from retaining a worker
/// thread until the outer CI timeout kills the process.
final class TestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpenValue = false

    var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isOpenValue
    }

    func open() {
        condition.lock()
        isOpenValue = true
        condition.broadcast()
        condition.unlock()
    }

    func waitSynchronously(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isOpenValue {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func waitUntilOpen(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isOpen, clock.now < deadline {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isOpen
    }
}
