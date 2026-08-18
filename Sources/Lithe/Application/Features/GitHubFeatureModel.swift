import Combine
import Foundation
import LitheCoreContracts

@MainActor
final class GitHubFeatureModel: ObservableObject {
    private enum Constants {
        static let branchCacheLifetime: TimeInterval = 60
    }

    enum ConnectionState: Equatable {
        case disconnected
        case restoring
        case authorizing(GitHubDeviceAuthorization)
        case connected(GitHubUser)
        case failed(String)
    }

    enum ContentState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum OperationState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var contentState: ContentState = .idle
    @Published private(set) var repository: GitHubRepository?
    @Published private(set) var pullRequests: [GitHubPullRequest] = []
    @Published private(set) var branches: [GitHubBranch] = []
    @Published private(set) var branchContentState: ContentState = .idle
    @Published private(set) var branchRefreshError: String?
    @Published private(set) var pullRequestBranchDefaults = GitHubPullRequestBranchDefaults(
        head: nil,
        base: nil
    )
    @Published private(set) var selectedPullRequest: GitHubPullRequest?
    @Published private(set) var files: [GitHubPullRequestFile] = []
    @Published private(set) var comments: [GitHubComment] = []
    @Published private(set) var operationState: OperationState = .idle
    @Published private(set) var isCreatingPullRequest = false
    @Published private(set) var isPublishingPullRequestBranch = false
    @Published private(set) var branchPublicationError: String?
    @Published private(set) var canUseDeviceFlow = false
    @Published var listState = "open"
    private let service: GitHubService
    private let branchCacheLifetime: TimeInterval
    private let currentDate: () -> Date
    private var authorizationTask: Task<Void, Never>?
    private var branchLoadTask: (id: UUID, task: Task<[GitHubBranch], Error>)?
    private var branchesLoadedAt: Date?
    private var refreshGeneration = UUID()

    init(
        service: GitHubService,
        branchCacheLifetime: TimeInterval = Constants.branchCacheLifetime,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.branchCacheLifetime = branchCacheLifetime
        self.currentDate = currentDate
    }

    func restore(workspaceURL: URL?) async {
        connectionState = .restoring
        canUseDeviceFlow = await service.canUseDeviceFlow
        do {
            guard let user = try await service.restoreConnection() else {
                connectionState = .disconnected
                return
            }
            connectionState = .connected(user)
            await refresh(workspaceURL: workspaceURL)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func beginDeviceAuthorization(
        workspaceURL: URL?,
        onAuthorization: @escaping @MainActor (GitHubDeviceAuthorization) -> Void
    ) async {
        authorizationTask?.cancel()
        do {
            let authorization = try await service.startDeviceAuthorization()
            connectionState = .authorizing(authorization)
            onAuthorization(authorization)
            authorizationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let user = try await self.service.finishDeviceAuthorization(authorization)
                    guard !Task.isCancelled else { return }
                    self.connectionState = .connected(user)
                    await self.refresh(workspaceURL: workspaceURL)
                } catch is CancellationError {
                    self.connectionState = .disconnected
                } catch {
                    self.connectionState = .failed(error.localizedDescription)
                }
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func connect(personalAccessToken: String, workspaceURL: URL?) async {
        authorizationTask?.cancel()
        connectionState = .restoring
        do {
            let user = try await service.connect(personalAccessToken: personalAccessToken)
            connectionState = .connected(user)
            await refresh(workspaceURL: workspaceURL)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        authorizationTask?.cancel()
        do {
            try await service.disconnect()
            connectionState = .disconnected
            repository = nil
            pullRequests = []
            branches = []
            branchContentState = .idle
            invalidateBranchCache()
            pullRequestBranchDefaults = GitHubPullRequestBranchDefaults(head: nil, base: nil)
            selectedPullRequest = nil
            files = []
            comments = []
            contentState = .idle
            operationState = .idle
            isCreatingPullRequest = false
            isPublishingPullRequestBranch = false
            branchPublicationError = nil
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func refresh(workspaceURL: URL?) async {
        guard case .connected = connectionState else { return }
        let generation = UUID()
        refreshGeneration = generation
        contentState = .loading
        do {
            let repository = try await service.resolveRepository(at: workspaceURL)
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            let branchDefaults = try await service.resolvePullRequestBranchDefaults(at: workspaceURL)
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            let pullRequests = try await service.listPullRequests(
                repository: repository,
                state: listState
            )
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            if self.repository != repository {
                branches = []
                branchContentState = .idle
                invalidateBranchCache()
            }
            self.repository = repository
            pullRequestBranchDefaults = branchDefaults
            self.pullRequests = pullRequests
            if let selectedNumber = selectedPullRequest?.number,
               pullRequests.contains(where: { $0.number == selectedNumber }) {
                await selectPullRequest(number: selectedNumber)
            } else {
                selectedPullRequest = nil
                files = []
                comments = []
            }
            contentState = .ready
        } catch {
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            contentState = .failed(error.localizedDescription)
        }
    }

    func loadBranches(force: Bool = false) async {
        guard let repository else { return }
        if !force, isBranchCacheFresh { return }
        if branches.isEmpty {
            branchContentState = .loading
        }
        branchRefreshError = nil

        let load: (id: UUID, task: Task<[GitHubBranch], Error>)
        if let branchLoadTask {
            load = branchLoadTask
        } else {
            load = (
                UUID(),
                Task { try await service.listBranches(repository: repository) }
            )
            branchLoadTask = load
        }
        defer {
            if branchLoadTask?.id == load.id {
                branchLoadTask = nil
            }
        }

        do {
            let loadedBranches = try await load.task.value
            guard self.repository == repository else { return }
            branches = loadedBranches
            branchesLoadedAt = currentDate()
            branchContentState = .ready
        } catch {
            guard self.repository == repository else { return }
            branchRefreshError = error.localizedDescription
            branchContentState = branches.isEmpty
                ? .failed(error.localizedDescription)
                : .ready
        }
    }

    private var isBranchCacheFresh: Bool {
        guard branchContentState == .ready, let branchesLoadedAt else { return false }
        return currentDate().timeIntervalSince(branchesLoadedAt) < branchCacheLifetime
    }

    private func invalidateBranchCache() {
        branchLoadTask?.task.cancel()
        branchLoadTask = nil
        branchesLoadedAt = nil
        branchRefreshError = nil
    }

    func pullRequestDescriptionInput(
        base: String,
        head: String
    ) async throws -> PullRequestDescriptionInput {
        guard let repository else { throw GitHubService.ServiceError.noWorkspace }
        let comparison = try await service.compareBranches(
            repository: repository,
            base: base,
            head: head
        )
        return PullRequestDescriptionInput(
            repository: repository.fullName,
            base: base,
            head: head,
            commitMessages: comparison.commits.map(\.message),
            files: comparison.files.compactMap { file in
                guard let patch = file.patch,
                      !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return PullRequestDescriptionFileInput(
                    path: file.path,
                    changeKind: file.pullRequestDescriptionChangeKind,
                    patch: patch
                )
            }
        )
    }

    func publishPullRequestBranch(
        named name: String,
        workspaceURL: URL?
    ) async -> String? {
        let branch = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            branchPublicationError = String(localized: "Enter a branch name before publishing.")
            return nil
        }
        isPublishingPullRequestBranch = true
        branchPublicationError = nil
        defer { isPublishingPullRequestBranch = false }
        do {
            try await service.publishPullRequestBranch(named: branch, at: workspaceURL)
            let defaults = try await service.resolvePullRequestBranchDefaults(at: workspaceURL)
            pullRequestBranchDefaults = defaults
            await loadBranches(force: true)
            operationState = .succeeded("Branch published to GitHub")
            return defaults.head ?? branch
        } catch {
            branchPublicationError = error.localizedDescription
            return nil
        }
    }

    func selectPullRequest(number: UInt64) async {
        guard let repository else { return }
        isCreatingPullRequest = false
        contentState = .loading
        do {
            async let request = service.pullRequest(repository: repository, number: number)
            async let files = service.files(repository: repository, number: number)
            async let comments = service.comments(repository: repository, number: number)
            selectedPullRequest = try await request
            self.files = try await files
            self.comments = try await comments
            contentState = .ready
        } catch {
            contentState = .failed(error.localizedDescription)
        }
    }

    func createPullRequest(
        title: String,
        body: String,
        head: String,
        base: String,
        draft: Bool
    ) async -> Bool {
        guard let repository else { return false }
        operationState = .running("Creating pull request…")
        do {
            let request = try await service.createPullRequest(
                repository: repository,
                title: title,
                body: body,
                head: head,
                base: base,
                draft: draft
            )
            await refreshAfterMutation(selecting: request.number)
            operationState = .succeeded("Pull request created")
            isCreatingPullRequest = false
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func addComment(_ body: String) async -> Bool {
        guard let repository, let request = selectedPullRequest else { return false }
        operationState = .running("Posting comment…")
        do {
            let comment = try await service.addComment(
                repository: repository,
                number: request.number,
                body: body
            )
            comments.append(comment)
            comments.sort { $0.id < $1.id }
            operationState = .succeeded("Comment posted")
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func updatePullRequest(title: String, body: String, base: String) async -> Bool {
        guard let repository, let request = selectedPullRequest else { return false }
        operationState = .running("Updating pull request…")
        do {
            _ = try await service.updatePullRequest(
                repository: repository,
                number: request.number,
                title: title,
                body: body,
                base: base
            )
            await refreshAfterMutation(selecting: request.number)
            operationState = .succeeded("Pull request updated")
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func submitReview(event: String, body: String) async -> Bool {
        guard let repository, let request = selectedPullRequest else { return false }
        operationState = .running("Submitting review…")
        do {
            try await service.submitReview(
                repository: repository,
                number: request.number,
                event: event,
                body: body
            )
            await selectPullRequest(number: request.number)
            operationState = .succeeded(reviewSuccessMessage(event))
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func merge(method: String) async -> Bool {
        guard let repository, let request = selectedPullRequest else { return false }
        operationState = .running("Merging pull request…")
        do {
            _ = try await service.merge(
                repository: repository,
                number: request.number,
                method: method
            )
            await refreshAfterMutation(selecting: request.number)
            operationState = .succeeded("Pull request merged")
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func setOpen(_ isOpen: Bool) async {
        guard let repository, let request = selectedPullRequest else { return }
        operationState = .running(isOpen ? "Reopening pull request…" : "Closing pull request…")
        do {
            _ = try await service.updatePullRequest(
                repository: repository,
                number: request.number,
                state: isOpen ? "open" : "closed"
            )
            await refreshAfterMutation(selecting: request.number)
            operationState = .succeeded(isOpen ? "Pull request reopened" : "Pull request closed")
        } catch {
            operationState = .failed(error.localizedDescription)
        }
    }

    func updateMetadata(labels: [String], assignees: [String]) async -> Bool {
        guard let repository, let request = selectedPullRequest else { return false }
        operationState = .running("Updating labels and assignees…")
        do {
            try await service.updateMetadata(
                repository: repository,
                number: request.number,
                labels: labels,
                assignees: assignees
            )
            await selectPullRequest(number: request.number)
            operationState = .succeeded("Metadata updated")
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func checkout(workspaceURL: URL?) async -> Bool {
        guard let request = selectedPullRequest else { return false }
        operationState = .running("Checking out pull request…")
        do {
            try await service.checkout(request, at: workspaceURL)
            operationState = .succeeded("Pull request checked out as a local branch")
            return true
        } catch {
            operationState = .failed(error.localizedDescription)
            return false
        }
    }

    func clearOperationStatus() {
        if case .running = operationState { return }
        operationState = .idle
    }

    func beginCreatingPullRequest() {
        clearOperationStatus()
        isCreatingPullRequest = true
    }

    func cancelCreatingPullRequest() {
        guard !isOperationRunning else { return }
        clearOperationStatus()
        isCreatingPullRequest = false
    }

    private var isOperationRunning: Bool {
        if case .running = operationState { return true }
        return false
    }

    private func refreshAfterMutation(selecting number: UInt64) async {
        guard let repository else { return }
        do {
            pullRequests = try await service.listPullRequests(repository: repository, state: listState)
            await selectPullRequest(number: number)
        } catch {
            contentState = .failed(error.localizedDescription)
        }
    }

    private func reviewSuccessMessage(_ event: String) -> String {
        switch event {
        case "APPROVE": "Review approved"
        case "REQUEST_CHANGES": "Changes requested"
        default: "Review comment submitted"
        }
    }
}

private extension GitHubPullRequestFile {
    var pullRequestDescriptionChangeKind: CommitMessageChangeKind {
        switch status {
        case "added": .added
        case "removed": .deleted
        case "renamed": .renamed
        case "copied": .copied
        default: .modified
        }
    }
}
