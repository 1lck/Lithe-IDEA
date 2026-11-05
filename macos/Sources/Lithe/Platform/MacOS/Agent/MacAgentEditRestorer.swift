import Foundation
import LitheAgentConversationModule

/// Only explicit workspace rollback writes files. Installation resources remain
/// read-only; snapshots live in conversation memory, without a new disk cache.
struct MacAgentEditRestorer: AgentEditRestoring {
    let fileOperations: any WorkspaceFileOperations
    let planner: any AgentEditReversePlanning
    private static let queue = DispatchQueue(label: "app.lithe.agent-edit-review", qos: .userInitiated)

    func restore(_ change: AgentFileChange, in workspace: URL) async throws {
        let cancellation = AgentReviewCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.queue.async {
                    continuation.resume(with: Result { try restoreSynchronously(change, in: workspace, cancellation: cancellation) })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func restoreSynchronously(_ change: AgentFileChange, in workspace: URL, cancellation: AgentReviewCancellation) throws {
        try cancellation.check()
        guard change.canRevert else { throw AgentEditRestoreError.incomplete }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let location = AgentToolDetails.Location(path: change.path)
        guard let lexicalURL = location.fileURL(in: workspace) else { throw AgentEditRestoreError.outsideWorkspace }
        // Resolve parents for containment, but leave the selected terminal object
        // intact so the document adapter can reject a replacement symbolic link.
        let url = lexicalURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(lexicalURL.lastPathComponent)
        guard url.pathComponents.starts(with: root.pathComponents), url.pathComponents.count > root.pathComponents.count else {
            throw AgentEditRestoreError.outsideWorkspace
        }
        // Reuse the document adapter's size/link checks, encoding and byte identity.
        let disk = try fileOperations.readDocumentDetails(from: url, encoding: nil)
        try cancellation.check()
        // Core owns matching, line endings, deletion and conflict rules.
        switch try planner.reversePlan(for: change, disk: disk?.text) {
        case .none:
            return
        case .write(let restored):
            try cancellation.check()
            switch try fileOperations.writeDocumentText(restored, to: url, expectedContent: disk?.text,
                encoding: disk?.encoding ?? .utf8, expectedIdentity: disk?.identity) {
            case .saved: break
            case .conflict: throw AgentEditRestoreError.changed
            }
        case .trash:
            guard let disk else { throw AgentEditRestoreError.changed }
            guard let identity = disk.identity else { throw AgentEditRestoreError.unavailable }
            try cancellation.check()
            // New files go to recoverable Trash, never permanent deletion.
            guard case .trashed = try fileOperations.trashDocument(at: url, expectedIdentity: identity) else {
                throw AgentEditRestoreError.changed
            }
        }
    }
}

private final class AgentReviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
