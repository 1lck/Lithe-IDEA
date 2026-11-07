import Foundation

extension RustCoreBridge {
    /// One cached pasted image sent to `agent.attachments.retentionPlan`.
    struct AgentAttachmentEntry: Encodable, Sendable {
        let path: String
        let modifiedMs: Int64?
        let abandoned: Bool
    }

    /// Files Core says to delete; Swift only lists the cache and performs the removal.
    struct AgentAttachmentRetentionPlan: Decodable, Sendable {
        struct Decision: Decodable, Sendable {
            let path: String
            let reason: String
        }
        let delete: [Decision]
        let keep: [Decision]
        /// Images to write to a new ledger before deleting anything (empty once a ledger exists).
        let seed: [String]
    }

    func agentAttachmentRetentionPlan(
        nowMs: Int64, entries: [AgentAttachmentEntry], acceptedReferences: [String], ledgerPresent: Bool
    ) throws -> AgentAttachmentRetentionPlan {
        struct Request: Encodable {
            let nowMs: Int64
            let entries: [AgentAttachmentEntry]
            let acceptedReferences: [String]
            let ledgerPresent: Bool
            let caseInsensitive = false
        }
        let result: Result<AgentAttachmentRetentionPlan, CoreCallError> = executeResult(
            command: "agent.attachments.retentionPlan",
            payload: Request(nowMs: nowMs, entries: entries, acceptedReferences: acceptedReferences,
                           ledgerPresent: ledgerPresent)
        )
        return try result.get()
    }
}
