import Foundation
import LitheCoreContracts

@MainActor
final class MacDebugOperationDeadlineScheduler: DebugOperationDeadlineScheduling {
    func schedule(
        afterMilliseconds: Int,
        action: @escaping @MainActor () -> Void
    ) -> any DebugOperationDeadline {
        let item = DispatchWorkItem { action() }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(afterMilliseconds),
            execute: item
        )
        return MacDebugOperationDeadline(item: item)
    }
}

@MainActor
private final class MacDebugOperationDeadline: DebugOperationDeadline {
    private var item: DispatchWorkItem?

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item?.cancel()
        item = nil
    }

    deinit {
        item?.cancel()
    }
}
