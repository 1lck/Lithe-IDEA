import Foundation

/// Owns the cancellable tasks behind test discovery and test run preparation.
///
/// Each operation gets an identity so a replaced or cancelled task cannot clear
/// or publish over the state of the task that superseded it.
@MainActor
final class LanguageTestWorkflowState {
    var runPreparationTask: Task<Void, Never>?
    private var runPreparationID: UUID?

    func beginRunPreparation() -> UUID {
        cancelRunPreparation()
        let id = UUID()
        runPreparationID = id
        return id
    }
    func isCurrentRunPreparation(_ id: UUID) -> Bool { runPreparationID == id && !Task.isCancelled }
    func finishRunPreparation(_ id: UUID) {
        guard runPreparationID == id else { return }
        runPreparationID = nil
        runPreparationTask = nil
    }
    func cancelRunPreparation() {
        runPreparationID = nil
        runPreparationTask?.cancel()
        runPreparationTask = nil
    }

    var discoveryTask: Task<Void, Never>?
    var discoveryOperationID: UUID?

    func beginDiscovery() -> UUID {
        cancelDiscovery()
        let operationID = UUID()
        discoveryOperationID = operationID
        return operationID
    }

    func cancelDiscovery() {
        discoveryOperationID = nil
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    func isCurrentDiscovery(_ operationID: UUID) -> Bool {
        discoveryOperationID == operationID && !Task.isCancelled
    }

    func finishDiscovery(_ operationID: UUID) {
        guard discoveryOperationID == operationID else { return }
        discoveryOperationID = nil
        discoveryTask = nil
    }
}
