import Combine
import Foundation

/// Window-owned history shared by Git feature workflows, GitHub actions and
/// requests made before the Git feature activates.
/// Native callbacks only update bounded storage; consumers coalesce publication.
package final class GitExecutionJournal: @unchecked Sendable {
    package let changes = PassthroughSubject<Void, Never>()
    private let lock = NSLock()
    private var contexts: [String: GitExecutionContext] = [:]
    // Request bookkeeping survives preflight and clearing without inventing a command row.
    private var activeRequests: Set<String> = []
    private var requestRoots: [String: URL] = [:]
    private var runningOperations: Set<String> = []
    private var entries: [GitConsoleEntry] = []
    private var entryIDs: [String: Set<UUID>] = [:]
    private var hidden: Set<String> = []
    private var omittedHistory = false

    package init() {}

    package var hasOmittedHistory: Bool { lock.withLock { omittedHistory } }
    package var snapshot: [GitConsoleEntry] { lock.withLock { entries } }
    package var runningOperationIDs: Set<String> { lock.withLock { runningOperations } }

    /// Feature-owned workflows publish the same invocation IDs to window history,
    /// so closing their panel or opening a linked checkout cannot lose the command.
    package func record(_ snapshot: [GitConsoleEntry], operationID: String? = nil) {
        guard !snapshot.isEmpty else { return }
        let changed = lock.withLock {
            if let operationID, hidden.contains(operationID) { return false }
            retain(snapshot)
            if let operationID { entryIDs[operationID] = Set(snapshot.map(\.id)) }
            return true
        }
        if changed { changes.send() }
    }

    package func finishRecording(_ operationID: String) {
        lock.withLock { entryIDs.removeValue(forKey: operationID); _ = hidden.remove(operationID) }
    }

    private func retain(_ snapshot: [GitConsoleEntry]) {
        for entry in snapshot {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        if entries.count > 200 { omittedHistory = true; entries.removeFirst(entries.count - 200) }
        while entries.count > 1 && entries.reduce(0, { $0 + $1.output.count }) > 1_048_576 {
            omittedHistory = true
            entries.removeFirst()
        }
    }

    package func receive(_ event: GitExecutionEvent, at root: URL? = nil) {
        let changed = lock.withLock { receiveLocked(event, root: root) }
        if changed { changes.send() }
    }

    private func receiveLocked(_ event: GitExecutionEvent, root: URL?) -> Bool {
        let operationID = event.operationId
        if event.type == "requestStarted" {
            activeRequests.insert(operationID)
            requestRoots[operationID] = root ?? event.workingDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            return false
        }
        if event.type == "requestFinished" {
            activeRequests.remove(operationID)
            let wasRunning = runningOperations.remove(operationID) != nil
            defer {
                contexts.removeValue(forKey: operationID)
                entryIDs.removeValue(forKey: operationID)
                requestRoots.removeValue(forKey: operationID)
            }
            if hidden.remove(operationID) != nil { return wasRunning }
            guard let context = contexts[operationID] else {
                guard let error = event.error, let root = requestRoots[operationID] ?? root else { return wasRunning }
                retain([GitConsoleEntry(workingDirectory: root, arguments: [], output: "", exitCode: -1,
                    state: .unconfirmed, operationErrorMessage: [error.message, error.details].compactMap { $0 }.joined(separator: "\n"))])
                return true
            }
            context.receive(event)
            if let snapshot = context.drainSnapshot() { retain(snapshot) }
            return true
        }
        let beganRunning: Bool
        if event.type == "started" {
            activeRequests.insert(operationID)
            beganRunning = runningOperations.insert(operationID).inserted
        } else {
            beganRunning = false
        }
        if hidden.contains(operationID) {
            return beganRunning
        }
        // Empty bookkeeping requests are not invented console commands.
        guard event.type == "started" || contexts[operationID] != nil else { return false }
        let context = contexts[operationID] ?? GitExecutionContext(operationID: operationID)
        contexts[operationID] = context
        context.receive(event)
        omittedHistory = omittedHistory || context.hasOmittedHistory
        let snapshot = context.drainSnapshot()
        if let snapshot {
            // Update in place to retain start order even when wall-clock
            // timestamps coincide or concurrent commands finish out of order.
            retain(snapshot)
            entryIDs[operationID] = Set(snapshot.map(\.id))
        }
        return snapshot != nil
    }

    package func clear(at root: URL? = nil) {
        lock.withLock {
            let removed = Set(entries.filter { root == nil || $0.workingDirectory.standardizedFileURL == root?.standardizedFileURL }.map(\.id))
            entries.removeAll { removed.contains($0.id) }
            if entries.isEmpty { omittedHistory = false }
            let suppressed = root == nil ? activeRequests.union(entryIDs.keys)
                : Set(entryIDs.compactMap { $0.value.isDisjoint(with: removed) ? nil : $0.key })
            for operationID in suppressed {
                hidden.insert(operationID)
                contexts.removeValue(forKey: operationID)
                entryIDs.removeValue(forKey: operationID)
            }
        }
        changes.send()
    }
}
