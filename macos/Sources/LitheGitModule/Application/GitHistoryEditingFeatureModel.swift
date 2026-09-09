import Combine
import Foundation

/// Owns history selection, preview and editing without coupling the Log to Git command construction.
@MainActor
package final class GitHistoryEditingFeatureModel: ObservableObject {
    package struct Outcome: Identifiable {
        package let id = UUID()
        package let succeeded: Bool
        package let message: String
        package let rewrite: GitHistoryRewriteResult?
        package let warnings: [GitOperationWarning]
    }

    @Published package private(set) var selection = GitHistorySelection()
    @Published package private(set) var preview: GitHistoryRewritePreview?
    @Published package private(set) var operation = GitHistoryRewriteOperation.undoCommit
    @Published package private(set) var isLoading = false
    @Published package private(set) var isExecuting = false
    @Published package private(set) var showsDialog = false
    @Published package private(set) var errorMessage: String?
    @Published package var title = ""
    @Published package var body = ""
    @Published package var outcome: Outcome?
    package var onCommitUndone: ((String) -> Void)?

    private let service: GitService
    private let execute: @MainActor (URL, GitHistoryRewriteExpectedState, String?) async -> GitService.CommandResult?
    private var repositoryRoot: URL?
    private var revisions: [String] = []
    private var generation: UInt64 = 0
    private var previewTask: Task<Void, Never>?

    package init(
        service: GitService,
        execute: @escaping @MainActor (URL, GitHistoryRewriteExpectedState, String?) async -> GitService.CommandResult?
    ) {
        self.service = service
        self.execute = execute
    }

    package var isBusy: Bool { isLoading || isExecuting }
    package var message: String {
        let subject = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
    }
    package var canExecute: Bool {
        !isBusy && preview?.allowed == true && preview?.expectedState != nil
            && (!operation.editsMessage || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    package func select(_ hash: String, visibleHashes: [String], additive: Bool, range: Bool) {
        selection.select(hash, visibleHashes: visibleHashes, additive: additive, range: range)
    }

    package func selectForContextMenu(_ hash: String) {
        selection.selectForContextMenu(hash)
    }

    package func retainSelection(in commits: [GitCommit], fallback: String?) {
        selection.retain(Set(commits.map(\.hash)), fallback: fallback)
    }

    package func begin(_ operation: GitHistoryRewriteOperation, at root: URL, clickedHash: String) {
        guard !isExecuting else { return }
        selection.selectForContextMenu(clickedHash)
        self.operation = operation
        repositoryRoot = root
        revisions = operation == .squashCommits ? selection.hashes.sorted() : [clickedHash]
        title = ""
        body = ""
        showsDialog = true
        loadPreview(preserveMessage: false)
    }

    package func reloadPreview() { loadPreview(preserveMessage: true) }

    private func loadPreview(preserveMessage: Bool) {
        guard let repositoryRoot, !isExecuting else { return }
        previewTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let operation = operation
        let revisions = revisions
        preview = nil
        errorMessage = nil
        isLoading = true
        previewTask = Task { [weak self, service] in
            let preview = await service.historyRewritePreview(at: repositoryRoot, operation: operation, revisions: revisions)
            guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
            self.isLoading = false
            self.previewTask = nil
            guard let preview else {
                self.errorMessage = "Could not inspect the selected history. Refresh the preview to retry."
                return
            }
            self.preview = preview
            if !preserveMessage {
                let lines = preview.suggestedMessage.components(separatedBy: "\n")
                self.title = lines.first ?? ""
                var bodyLines = Array(lines.dropFirst())
                if bodyLines.first == "" { bodyLines.removeFirst() }
                self.body = bodyLines.joined(separator: "\n")
            }
        }
    }

    package func confirm() async {
        guard canExecute, let repositoryRoot, let expectedState = preview?.expectedState else { return }
        let requestGeneration = generation
        let originalMessage = preview?.selectedCommits.first?.message ?? ""
        isExecuting = true
        errorMessage = nil
        let result = await execute(repositoryRoot, expectedState, operation.editsMessage ? message : nil)
        guard generation == requestGeneration else { return }
        isExecuting = false
        guard let result else {
            errorMessage = "The repository changed or another Git operation is running. Refresh the preview to retry."
            preview = nil
            return
        }
        let resultMessage = result.succeeded ? successMessage : result.output
        outcome = Outcome(succeeded: result.succeeded, message: resultMessage, rewrite: result.historyRewrite, warnings: result.warnings)
        if result.succeeded {
            showsDialog = false
            preview = nil
            if operation == .undoCommit, result.historyRewrite?.mutationApplied == true,
               result.historyRewrite?.outcomeKnown == true {
                onCommitUndone?(originalMessage)
            }
        } else {
            errorMessage = resultMessage
            // A failed write may have partially applied; every retry requires a fresh snapshot.
            preview = nil
        }
    }

    package func dismiss() {
        guard !isExecuting else { return }
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        isLoading = false
        showsDialog = false
        preview = nil
        errorMessage = nil
    }

    package func reset() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        selection = GitHistorySelection()
        preview = nil
        repositoryRoot = nil
        revisions = []
        showsDialog = false
        isLoading = false
        isExecuting = false
        errorMessage = nil
        outcome = nil
    }

    private var successMessage: String {
        switch operation {
        case .undoCommit: "HEAD moved to its parent. The index and working files were preserved."
        case .editCommitMessage: "Commit message updated."
        case .squashCommits: "Selected commits squashed into one commit."
        case .deleteCommit: "Commit dropped from the current branch."
        }
    }
}
