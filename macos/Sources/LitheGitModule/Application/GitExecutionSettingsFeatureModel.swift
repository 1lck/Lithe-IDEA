import Combine
import Foundation

@MainActor
package final class GitExecutionSettingsFeatureModel: ObservableObject {
    @Published package private(set) var snapshot: GitExecutionSettingsSnapshot?
    @Published package private(set) var isBusy = false
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var savedKey: String?
    private var generation = 0
    private let service: GitService
    package init(service: GitService) { self.service = service }
    package func reset() { generation &+= 1; snapshot = nil; isBusy = false; errorMessage = nil; savedKey = nil }
    package func load(at root: URL?, scope: String = "local") async {
        reset()
        guard let root else { return }
        let generation = generation
        isBusy = true
        let result = await service.executionSettings(.init(root: root, scope: scope), save: false)
        guard generation == self.generation else { return }
        receive(result)
    }
    package func save(at root: URL, field: GitConfigurationField, value: String?) async {
        guard let snapshot, !isBusy else { return }
        let generation = generation
        isBusy = true; errorMessage = nil; savedKey = nil
        let result = await service.executionSettings(.init(root: root, scope: snapshot.scope,
            key: field.key, value: value, expectedValues: field.configuredValues), save: true)
        guard generation == self.generation else { return }
        receive(result)
        if errorMessage == nil { savedKey = field.key }
    }
    private func receive(_ result: Result<GitExecutionSettingsSnapshot, GitFetchFailure>) {
        isBusy = false
        switch result {
        case .success(let snapshot): self.snapshot = snapshot
        case .failure(let error): errorMessage = error.message
        }
    }
}
