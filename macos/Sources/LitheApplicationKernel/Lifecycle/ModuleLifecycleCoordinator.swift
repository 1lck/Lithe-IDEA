import Foundation

/// Drives idle evaluation without making the application shell own a timer.
/// The coordinator itself is application-scoped and stops deterministically
/// during project/session shutdown.
@MainActor
public final class ModuleLifecycleCoordinator {
    private let runtime: ModuleRuntime
    private let evaluationInterval: Duration
    private var task: Task<Void, Never>?

    public init(runtime: ModuleRuntime, evaluationInterval: Duration = .seconds(30)) {
        self.runtime = runtime
        self.evaluationInterval = evaluationInterval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                // log-exempt: 用户取消：调用方取消等待或替换旧任务时结束延迟，不代表操作失败
                try? await Task.sleep(for: self.evaluationInterval)
                guard !Task.isCancelled else { return }
                await self.runtime.evaluateIdleModules()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
