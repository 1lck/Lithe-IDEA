import Combine
import Foundation

/// Application-owned history for Git requests launched outside the Git feature's
/// workflow context, including GitHub actions and calls made before it activates.
/// Native callbacks only update bounded storage; consumers coalesce publication.
package final class GitExecutionJournal: @unchecked Sendable {
    package let changes = PassthroughSubject<Void, Never>()
    private let lock = NSLock()
    private var contexts: [String: GitExecutionContext] = [:]
    private var entries: [GitConsoleEntry] = []
    private var entryIDs: [String: Set<UUID>] = [:]
    private var hidden: Set<String> = []

    package init() {}

    package var snapshot: [GitConsoleEntry] { lock.withLock { entries } }

    package func receive(_ event: GitExecutionEvent) {
        let changed = lock.withLock { receiveLocked(event) }
        if changed { changes.send() }
    }

    private func receiveLocked(_ event: GitExecutionEvent) -> Bool {
        let operationID = event.operationId
        if hidden.contains(operationID) {
            if event.type == "requestFinished" { hidden.remove(operationID) }
            return false
        }
        // Empty bookkeeping requests are not invented console commands.
        guard event.type == "started" || contexts[operationID] != nil else { return false }
        let context = contexts[operationID] ?? GitExecutionContext(operationID: operationID)
        contexts[operationID] = context
        context.receive(event)
        let snapshot = context.drainSnapshot()
        if let snapshot {
            // Update in place to retain start order even when wall-clock
            // timestamps coincide or concurrent commands finish out of order.
            for entry in snapshot {
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index] = entry
                } else {
                    entries.append(entry)
                }
            }
            entryIDs[operationID] = Set(snapshot.map(\.id))
            if entries.count > 200 { entries.removeFirst(entries.count - 200) }
            while entries.count > 1 && entries.reduce(0, { $0 + $1.output.count }) > 1_048_576 {
                entries.removeFirst()
            }
        }
        if event.type == "requestFinished" {
            contexts.removeValue(forKey: operationID)
            entryIDs.removeValue(forKey: operationID)
        }
        return snapshot != nil
    }

    package func clear(at root: URL) {
        lock.withLock {
            let removed = Set(entries.filter { $0.workingDirectory == root }.map(\.id))
            entries.removeAll { removed.contains($0.id) }
            for (operationID, ids) in entryIDs where !ids.isDisjoint(with: removed) {
                hidden.insert(operationID)
                contexts.removeValue(forKey: operationID)
                entryIDs.removeValue(forKey: operationID)
            }
        }
        changes.send()
    }
}
