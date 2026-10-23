import Foundation

/// Replays an early cancellation at Core's synchronous registration callback.
/// The callback precedes dispatch, so even a short file mutation cannot outrun
/// a timer retry. No registration or worker outlives the enclosing C ABI call.
final class RustCoreCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let core: RustCoreBridge
    private let operationID: String
    private var cancelled = false

    init(core: RustCoreBridge, operationID: String) {
        self.core = core
        self.operationID = operationID
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        core.cancel(operationID: operationID)
    }

    func receive(_ event: String) {
        struct Registration: Decodable { let type: String }
        guard let registration = try? JSONDecoder().decode(Registration.self, from: Data(event.utf8)),
              registration.type == "requestStarted", isCancelled else { return }
        core.cancel(operationID: operationID)
    }
}
