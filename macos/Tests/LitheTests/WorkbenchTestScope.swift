import Testing

/// Owns asynchronous work until session cleanup has released its resources.
@MainActor
final class WorkbenchTestScope {
    struct DeadlineExceeded: Error, Equatable {
        let operation: String
    }

    private var pending: [(name: String, task: Task<Void, Never>, completed: TestGate)] = []

    func run(_ name: String, timeout: Duration = .seconds(2),
             operation: @escaping @MainActor () async throws -> Void) async throws {
        let completed = TestGate()
        var result: Result<Void, Error>?
        let task = Task { @MainActor in
            defer { completed.open() }
            do { try await operation(); result = .success(()) }
            catch { result = .failure(error) }
        }
        pending.append((name, task, completed))
        guard await completed.waitUntilOpen(timeout: timeout) else {
            task.cancel()
            throw DeadlineExceeded(operation: name)
        }
        try result!.get()
    }

    static func withCleanup(_ cleanup: @escaping @MainActor () async throws -> Void,
                            body: (WorkbenchTestScope) async throws -> Void) async throws {
        let scope = WorkbenchTestScope()
        var failure: Error?
        do { try await body(scope) } catch { failure = error }
        // Body defers release test gates and cancel UI requests before shutdown.
        do { try await scope.run("session shutdown", operation: cleanup) }
        catch {
            if failure == nil { failure = error }
            else { Issue.record("Session cleanup failed: \(error)") }
        }
        for operation in scope.pending {
            operation.task.cancel()
            // Joining is safe only after the task's final defer signals completion.
            if await operation.completed.waitUntilOpen(timeout: .seconds(2)) {
                await operation.task.value
            } else {
                Issue.record("Operation did not terminate after cleanup: \(operation.name)")
            }
        }
        if let failure { throw failure }
    }
}

@MainActor
struct WorkbenchTestScopeTests {
    private struct BodyFailure: Error {}

    @Test func thrownBodyStillRunsAndAwaitsCleanup() async throws {
        let released = TestGate()
        var cleaned = false
        do {
            try await WorkbenchTestScope.withCleanup({
                #expect(released.isOpen)
                cleaned = true
            }) { _ in
                defer { released.open() }
                throw BodyFailure()
            }
            Issue.record("The body error was lost")
        } catch is BodyFailure {}
        #expect(cleaned)
    }

    @Test func deadlineCancelsWorkAndJoinsItAfterCleanup() async throws {
        let started = TestGate(), release = TestGate(), finished = TestGate()
        var cancelled = false, cleaned = false
        do {
            try await WorkbenchTestScope.withCleanup({
                release.open()
                cleaned = true
            }) { scope in
                // A zero deadline exercises failure without waiting for wall time.
                try await scope.run("gated operation", timeout: .zero) {
                    defer { finished.open() }
                    started.open()
                    _ = await release.waitUntilOpen()
                    cancelled = Task.isCancelled
                }
            }
            Issue.record("The deadline did not fail")
        } catch let error as WorkbenchTestScope.DeadlineExceeded {
            #expect(error.operation == "gated operation")
        }
        #expect(started.isOpen && finished.isOpen && cleaned && cancelled)
    }

    @Test func timedOutTaskValueWaitFinishesWhenCleanupReleasesTheWorker() async throws {
        let release = TestGate(), finished = TestGate()
        let worker = Task {
            defer { finished.open() }
            _ = await release.waitUntilOpen()
        }
        defer { worker.cancel(); release.open() }
        do {
            try await WorkbenchTestScope.withCleanup({ release.open() }) { scope in
                // Cancelling the observer cannot interrupt a Task.value wait.
                try await scope.run("worker join", timeout: .zero) { await worker.value }
            }
            Issue.record("The deadline did not fail")
        } catch let error as WorkbenchTestScope.DeadlineExceeded {
            #expect(error.operation == "worker join")
        }
        #expect(finished.isOpen)
    }
}
