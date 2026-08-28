import Foundation

/// One-shot coordination primitive for test doubles that implement synchronous
/// protocols. The deadline prevents a failed test from retaining a worker
/// thread until the outer CI timeout kills the process.
final class TestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpenValue = false
    private var asyncWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isOpenValue
    }

    func open() {
        condition.lock()
        isOpenValue = true
        let waiters = Array(asyncWaiters.values)
        let tasks = Array(timeoutTasks.values)
        asyncWaiters.removeAll()
        timeoutTasks.removeAll()
        condition.broadcast()
        condition.unlock()
        tasks.forEach { $0.cancel() }
        waiters.forEach { $0.resume(returning: true) }
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
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                guard !isOpenValue else {
                    condition.unlock()
                    continuation.resume(returning: true)
                    return
                }
                asyncWaiters[waiterID] = continuation
                condition.unlock()

                let timeoutTask = Task { [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: the gate deadline bounds a failed asynchronous test while successful signaling remains continuation-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishAsyncWaiter(waiterID, result: false)
                }
                condition.lock()
                if asyncWaiters[waiterID] == nil {
                    condition.unlock()
                    timeoutTask.cancel()
                } else {
                    timeoutTasks[waiterID] = timeoutTask
                    condition.unlock()
                }
                if Task.isCancelled {
                    finishAsyncWaiter(waiterID, result: false)
                }
            }
        } onCancel: {
            finishAsyncWaiter(waiterID, result: false)
        }
    }

    private func finishAsyncWaiter(_ waiterID: UUID, result: Bool) {
        condition.lock()
        let waiter = asyncWaiters.removeValue(forKey: waiterID)
        let timeoutTask = timeoutTasks.removeValue(forKey: waiterID)
        condition.unlock()
        timeoutTask?.cancel()
        waiter?.resume(returning: result)
    }
}
