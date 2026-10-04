import Foundation
import LitheAgentConversationModule

/// Only explicit workspace rollback writes files. Installation resources remain
/// read-only; snapshots live in conversation memory, without a new disk cache.
struct MacAgentEditRestorer: AgentEditRestoring {
    let fileOperations: any WorkspaceFileOperations
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
        let url = lexicalURL.resolvingSymlinksInPath()
        guard url.pathComponents.starts(with: root.pathComponents), url.pathComponents.count > root.pathComponents.count else {
            throw AgentEditRestoreError.outsideWorkspace
        }
        // Reuse the document adapter's size/link checks, encoding and byte identity.
        let disk = try fileOperations.readDocumentDetails(from: url, encoding: nil)
        var restored = disk?.text
        for diff in change.diffs.reversed() {
            try cancellation.check()
            if diff.operation == "delete" || (change.isDeletion && change.diffs.count == 1) {
                guard restored == nil, let old = diff.oldText else { throw AgentEditRestoreError.changed }
                restored = old
            } else if let old = diff.oldText {
                guard let current = restored else { throw AgentEditRestoreError.changed }
                if current == diff.newText { restored = old }
                else {
                    // Claude sometimes supplies an excerpt. Reverse only one
                    // exact nonempty match; ambiguous or missing text is a conflict.
                    guard !diff.newText.isEmpty, let range = current.range(of: diff.newText),
                          current.range(of: diff.newText, range: current.index(after: range.lowerBound)..<current.endIndex) == nil else {
                        throw AgentEditRestoreError.changed
                    }
                    restored = current.replacingCharacters(in: range, with: old)
                }
            } else {
                // Null oldText also appears for inserted excerpts. Only explicit
                // upstream creation metadata proves that the file can be removed.
                guard diff.operation == "add" else { throw AgentEditRestoreError.incomplete }
                guard restored == diff.newText else { throw AgentEditRestoreError.changed }
                restored = nil
            }
        }
        try cancellation.check()
        if let restored {
            switch try fileOperations.writeDocumentText(restored, to: url, expectedContent: disk?.text,
                encoding: disk?.encoding ?? .utf8, expectedIdentity: disk?.identity) {
            case .saved: break
            case .conflict: throw AgentEditRestoreError.changed
            }
        } else if let disk {
            let latest = try fileOperations.readDocumentDetails(from: url, encoding: nil)
            guard latest?.identity == disk.identity, latest?.text == disk.text else { throw AgentEditRestoreError.changed }
            try cancellation.check()
            // New files go to recoverable Trash, never permanent deletion.
            try fileOperations.trashItem(at: url)
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
