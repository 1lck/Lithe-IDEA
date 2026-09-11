import Foundation

/// Serializes MainActor async actions so later clicks cannot finish before earlier ones.
@MainActor
final class SerialMainActorActionQueue {
    private var serial = 0
    private var tail: Task<Void, Never>?
    private(set) var isBusy = false

    func enqueue(_ body: @escaping @MainActor () async -> Void) {
        serial += 1
        let token = serial
        isBusy = true
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await body()
            if token == self.serial {
                self.isBusy = false
            }
        }
    }
}
