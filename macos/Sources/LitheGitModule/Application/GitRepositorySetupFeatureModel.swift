import Combine
import Foundation

/// Settings owns drafts; the same inspected state supports first-commit guidance.
@MainActor
package final class GitRepositorySetupFeatureModel: ObservableObject {
    @Published package private(set) var state: GitRepositorySetup?
    @Published package private(set) var isBusy = false
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var savedField: GitIdentityField?
    @Published package var name = ""
    @Published package var email = ""
    package private(set) var scope = GitIdentityScope.local
    private var root: URL?
    private var generation = 0
    private let service: GitService

    package init(service: GitService) { self.service = service }

    package func reset() {
        generation &+= 1
        root = nil
        state = nil
        name = ""
        email = ""
        isBusy = false
        errorMessage = nil
        savedField = nil
    }

    package func load(at root: URL?, scope: GitIdentityScope = .local) async {
        reset()
        self.root = root
        self.scope = scope
        guard let root else { return }
        let generation = generation
        isBusy = true
        let result = await service.repositorySetup(at: root, scope: scope)
        guard self.generation == generation else { return }
        isBusy = false
        receive(result)
        name = state?.configuredName ?? ""
        email = state?.configuredEmail ?? ""
    }

    package func initialize() async -> Bool {
        guard let root, !isBusy, state?.isRepository == false else { return false }
        let generation = generation
        isBusy = true
        errorMessage = nil
        let result = await service.initializeRepository(at: root)
        guard self.generation == generation else { return false }
        isBusy = false
        receive(result)
        return state?.isRepository == true && errorMessage == nil
    }

    package func save(_ field: GitIdentityField, clear: Bool = false) async {
        guard let root, !isBusy, scope == .global || state?.isRepository == true else { return }
        let value = clear ? nil : (field == .name ? name : email).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == nil || value?.isEmpty == false else { return }
        let generation = generation
        isBusy = true
        savedField = nil
        errorMessage = nil
        let result = await service.configureIdentity(at: root, scope: scope, field: field, value: value)
        guard self.generation == generation else { return }
        isBusy = false
        receive(result)
        if errorMessage == nil {
            // Keep an unsaved draft in the other field intact.
            if field == .name { name = state?.configuredName ?? "" }
            else { email = state?.configuredEmail ?? "" }
            savedField = field
        }
    }

    private func receive(_ result: Result<GitRepositorySetup, GitSetupFailure>) {
        switch result {
        case .success(let state): self.state = state
        case .failure(let error): errorMessage = error.message
        }
    }
}
