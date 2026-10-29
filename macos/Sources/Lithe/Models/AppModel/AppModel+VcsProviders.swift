import Foundation
import LitheCoreContracts

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

@MainActor
extension AppModel {
    /// Plugin VCS providers; nil when no installed plugin declares one.
    var vcsProvidersFeature: VcsProvidersFeatureModel? { services.vcsProviders }

    /// Detects the workspace's plugin VCS roots once per workspace; later
    /// changes arrive through `handleVcsProviderFileChanges`.
    func loadVcsProviders(at workspaceURL: URL) {
        guard let feature = vcsProvidersFeature,
              feature.workspaceURL != workspaceURL.standardizedFileURL else { return }
        feature.reset(workspaceURL: workspaceURL)
    }

    func handleVcsProviderFileChanges(_ changes: [WorkspaceFileChange]) {
        vcsProvidersFeature?.workspaceFilesChanged(changes)
    }

    func showVcsDiffInNewTab(_ change: VcsChange, rootID: String) {
        guard let feature = vcsProvidersFeature else { return }
        let generation = workspaceFeature.workspaceGeneration
        let id = beginRepositoryDiffRequest(isProvider: true)
        let tabs = editorTabOrderFeature
        tabs.providerDiffTasks[id] = Task { [weak self, weak tabs] in
            defer { tabs?.providerDiffTasks[id] = nil }
            do {
                let diff = try await feature.diff(for: change, in: rootID)
                guard let self, self.workspaceFeature.workspaceGeneration == generation, !Task.isCancelled,
                      self.editorTabOrderFeature.contains(.repositoryDiff(id)) else { return }
                self.editorTabOrderFeature.providerDiffs[id] = diff
                self.editorTabOrderFeature.loadingProviderDiffs.remove(id)
            } catch is CancellationError {
                if let self, self.workspaceFeature.workspaceGeneration == generation { self.closeRepositoryDiffTab(id) }
            } catch {
                guard let self, self.workspaceFeature.workspaceGeneration == generation, !Task.isCancelled,
                      self.editorTabOrderFeature.contains(.repositoryDiff(id)) else { return }
                self.closeRepositoryDiffTab(id)
                feature.report(VcsProvidersFeatureModel.message(for: error), rootID: rootID)
            }
        }
    }

    func requestDeleteVcsFiles(_ changes: [VcsChange], rootID: String) {
        guard let feature = vcsProvidersFeature, let root = feature.root(rootID) else { return }
        let unversioned = changes.allSatisfy { $0.status == .unversioned }
        guard feature.canTrash(changes, in: rootID) || feature.canDelete(changes, in: rootID) else { return }
        let generation = workspaceFeature.workspaceGeneration
        let deletion = commitFileDeletion
        let isCurrent: @MainActor () -> Bool = { [weak self, weak feature] in
            self?.workspaceFeature.workspaceGeneration == generation && feature?.root(rootID)?.root == root.root
        }
        let delete: @MainActor ([URL]) async -> Bool
        if unversioned {
            delete = { [weak feature, weak deletion] urls in
                guard let feature, let deletion else { return false }
                return await feature.trash(changes, in: rootID) {
                    await deletion.trash(urls, root: root.url, isCurrent: isCurrent)
                }
            }
        } else {
            delete = { [weak feature] _ in await feature?.delete(changes, in: rootID) ?? false }
        }
        commitFileDeletion.request(changes.map { root.url.appendingPathComponent($0.path) }, root: root.url,
            usesVcs: !unversioned, isCurrent: isCurrent,
            isEligible: { [weak feature] in
                (unversioned ? feature?.canTrash(changes, in: rootID) : feature?.canDelete(changes, in: rootID)) == true
            }, delete: delete,
            refresh: { [weak self] in await self?.workspaceFeature.refreshCurrent() })
    }
}
