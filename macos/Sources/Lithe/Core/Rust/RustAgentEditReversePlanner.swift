import Foundation
import LitheAgentConversationModule

/// Rust Core-backed rollback planning (`agent.edits.reversePlan`). Matching,
/// line endings, deletion and conflict rules live in `lithe-agent-host`; this
/// adapter only encodes the evidence and maps the plan back into the port.
struct RustAgentEditReversePlanner: AgentEditReversePlanning {
    private let core: RustCoreBridge

    init(core: RustCoreBridge = RustCoreBridge()) {
        self.core = core
    }

    func reversePlan(for change: AgentFileChange, disk: String?) throws -> AgentEditReversePlan {
        struct Diff: Encodable {
            let oldText: String?
            let newText: String
            let operation: String?
            let toolKind: String?
            let truncated: Bool
        }
        struct Payload: Encodable {
            let diffs: [Diff]
            let pending: Bool
            let missingEvidence: Bool
            let disk: String?
        }
        struct Plan: Decodable {
            let action: String
            let text: String?
            let reason: String?
        }
        let payload = Payload(
            diffs: change.diffs.map {
                Diff(oldText: $0.oldText, newText: $0.newText, operation: $0.operation,
                     toolKind: $0.toolKind, truncated: $0.isTruncated)
            },
            pending: change.isPending, missingEvidence: change.hasMissingDiff, disk: disk)
        let plan: Plan
        do {
            plan = try core.executeResult(command: "agent.edits.reversePlan", payload: payload).get()
        } catch {
            throw AgentEditRestoreError.unavailable
        }
        switch (plan.action, plan.text, plan.reason) {
        case ("write", let text?, _): return .write(text)
        case ("trash", _, _): return .trash
        case ("none", _, _): return .none
        case ("conflict", _, "incomplete"): throw AgentEditRestoreError.incomplete
        case ("conflict", _, _): throw AgentEditRestoreError.changed
        default: throw AgentEditRestoreError.unavailable
        }
    }
}
