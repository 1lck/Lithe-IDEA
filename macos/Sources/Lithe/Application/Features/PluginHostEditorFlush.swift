import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// Waits for the editor to hand over input it has not reported yet, with a
/// bound.
///
/// The editor's synchronization callback may never arrive (a web view that is
/// loading or gone), and a service must not hang on it. The answer is true
/// only when the editor confirmed; a timeout or a failure is false, so the
/// caller treats the buffer as possibly newer than it knows.
@MainActor
enum PluginHostEditorFlush {
    nonisolated static let defaultTimeout: Duration = .seconds(2)

    /// `request` starts the synchronization and must call its argument once
    /// with the outcome. Later calls are ignored.
    static func run(
        timeout: Duration = defaultTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        request: (@escaping @MainActor @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        let waiter = Waiter()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiter.continuation = continuation
            // Started before the request, so a request that answers at once
            // cancels it instead of leaving it behind.
            waiter.timeout = Task { @MainActor in
                do { try await sleep(timeout) } catch { return }
                waiter.finish(false)
            }
            request { waiter.finish($0) }
        }
    }

    @MainActor
    private final class Waiter {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?

        func finish(_ confirmed: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(returning: confirmed)
        }
    }
}
