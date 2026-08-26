import Foundation

struct RustDocumentLifecycleDecider: DocumentLifecycleDeciding, Sendable {
    private let core: RustCoreBridge

    init(core: RustCoreBridge) {
        self.core = core
    }

    func decide(
        state: DocumentLifecycleState,
        event: DocumentLifecycleEvent,
        operationID: String
    ) throws -> DocumentLifecycleDecision {
        try core.documentLifecycleDecision(
            state: state,
            event: event,
            operationID: operationID
        ).get()
    }
}

extension RustCoreBridge {
    private struct DocumentLifecycleRequest: Encodable {
        let state: DocumentLifecycleState
        let event: DocumentLifecycleEvent
    }

    func documentLifecycleDecision(
        state: DocumentLifecycleState,
        event: DocumentLifecycleEvent,
        operationID: String
    ) -> Result<DocumentLifecycleDecision, CoreCallError> {
        executeResult(
            command: "document.lifecycle",
            payload: DocumentLifecycleRequest(state: state, event: event),
            operationID: operationID
        )
    }
}
