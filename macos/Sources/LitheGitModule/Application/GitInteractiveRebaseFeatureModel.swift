import Combine
import Foundation

/// Owns the editable todo plan and durable Core session; views never infer sequencer completion.
@MainActor
package final class GitInteractiveRebaseFeatureModel: ObservableObject {
    package enum Mutation {
        case start(GitRebaseExpectedState, [GitRebaseStep])
        case control(String, GitRebaseControlAction, String?)
    }

    @Published package private(set) var preview: GitRebasePreview?
    @Published private var plan = GitRebasePlanDraft()
    @Published package private(set) var session: GitRebaseSession?
    @Published package private(set) var isLoading = false
    @Published package private(set) var isExecuting = false
    @Published package private(set) var showsPlan = false
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var warnings: [GitOperationWarning] = []
    @Published package var selectedHash: String?
    private let service: GitService
    private let execute: @MainActor (URL, Mutation) async -> GitRebaseMutationResult?
    private var root: URL?
    private var baseRevision: String?
    private var generation: UInt64 = 0
    private var previewTask: Task<Void, Never>?
    private var dismissedSessionID: String?

    package init(service: GitService, execute: @escaping @MainActor (URL, Mutation) async -> GitRebaseMutationResult?) {
        self.service = service
        self.execute = execute
    }

    package var isBusy: Bool { isLoading || isExecuting }
    package var steps: [GitRebaseStep] { plan.steps }
    package var outputCommitCount: Int { plan.outputCommitCount }
    package var selectedStep: GitRebaseStep? { steps.first { $0.hash == selectedHash } }
    package var validationMessage: String? { plan.validationMessage }
    package var canStart: Bool {
        !isBusy && preview?.allowed == true && preview?.expectedState != nil && !steps.isEmpty && validationMessage == nil
    }

    package func begin(at root: URL, baseRevision: String) {
        guard !isExecuting else { return }
        self.root = root
        self.baseRevision = baseRevision
        showsPlan = true
        reloadPreview()
    }

    package func reloadPreview() {
        guard let root, let baseRevision, !isExecuting else { return }
        previewTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        preview = nil
        plan = GitRebasePlanDraft()
        selectedHash = nil
        errorMessage = nil
        isLoading = true
        previewTask = Task { [weak self, service] in
            let result = await service.interactiveRebasePreview(at: root, revision: baseRevision)
            guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
            self.isLoading = false
            self.previewTask = nil
            switch result {
            case .success(let preview):
                self.preview = preview
                self.plan = GitRebasePlanDraft(commits: preview.commits)
                self.selectedHash = self.steps.first?.hash
            case .failure(let error): self.errorMessage = error.message
            }
        }
    }

    package func subject(for hash: String) -> String { plan.subject(for: hash) }

    package func setAction(_ action: GitRebaseAction, for hash: String) {
        guard !isBusy else { return }
        plan.setAction(action, for: hash)
        selectedHash = hash
    }

    package func setMessage(_ message: String, for hash: String) {
        guard !isBusy else { return }
        plan.setMessage(message, for: hash)
    }

    package func useDefaultSquashMessage(for hash: String) {
        guard !isBusy else { return }
        plan.useDefaultSquashMessage(for: hash)
    }

    package func move(_ hash: String, by offset: Int) {
        guard !isBusy else { return }
        plan.move(hash, by: offset)
    }

    package func start() async {
        guard canStart, let root, let expectedState = preview?.expectedState else { return }
        let requestGeneration = generation
        let response = await perform(at: root, mutation: .start(expectedState, plan.wireSteps))
        guard requestGeneration == generation else { return }
        // A started session can stop for edit or conflicts even when the command exits successfully.
        if response?.session != nil { showsPlan = false }
        preview = nil
    }

    package func control(_ action: GitRebaseControlAction, amendMessage: String? = nil) async {
        guard !isBusy, let root, let session else { return }
        switch action {
        case .continue: guard session.canContinue else { return }
        case .skip: guard session.canSkip else { return }
        case .abort: guard session.canAbort else { return }
        }
        if let amendMessage {
            guard session.status == .edit, !amendMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        }
        _ = await perform(at: root, mutation: .control(session.sessionId, action, amendMessage))
    }

    package func amendAndContinue(_ message: String, from displayedSession: GitRebaseSession) async {
        guard let session, session.sessionId == displayedSession.sessionId,
              session.head == displayedSession.head, session.currentCommit == displayedSession.currentCommit,
              session.status == .edit else {
            errorMessage = "The edit stop changed. Refresh the session before amending."
            return
        }
        await control(.continue, amendMessage: message)
    }

    private func perform(at root: URL, mutation: Mutation) async -> GitRebaseMutationResult? {
        let requestGeneration = generation
        isExecuting = true
        errorMessage = nil
        let result = await execute(root, mutation)
        guard requestGeneration == generation else { return nil }
        isExecuting = false
        guard let result else {
            errorMessage = "The repository changed or another Git operation is running. Refresh before retrying."
            return nil
        }
        if let session = result.session {
            self.session = session
            dismissedSessionID = nil
        }
        warnings = result.command.warnings
        if !result.command.succeeded { errorMessage = result.command.output }
        return result
    }

    package func refreshSession(at root: URL) async {
        guard !isExecuting else { return }
        self.root = root
        let requestGeneration = generation
        let result = await service.interactiveRebaseSession(at: root)
        guard requestGeneration == generation, self.root == root, !isExecuting, !Task.isCancelled else { return }
        switch result {
        case .success(let next):
            if next?.sessionId != dismissedSessionID || next?.isActive == true { session = next }
        case .failure(let error):
            errorMessage = error.message
        }
    }

    package func dismissPlan() {
        guard !isExecuting else { return }
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        isLoading = false
        showsPlan = false
    }

    package func dismissSession() {
        guard session?.isActive != true, !isExecuting else { return }
        dismissedSessionID = session?.sessionId
        session = nil
        errorMessage = nil
        warnings = []
    }

    package func reset() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        root = nil
        baseRevision = nil
        preview = nil
        plan = GitRebasePlanDraft()
        session = nil
        selectedHash = nil
        isLoading = false
        isExecuting = false
        showsPlan = false
        errorMessage = nil
        warnings = []
        dismissedSessionID = nil
    }
}
