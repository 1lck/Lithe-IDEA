import Foundation
import LitheGitModule
import LitheModuleAPI

extension AppModel {
    func makeCommitFileDeletion() -> CommitFileDeletionFeatureModel {
        CommitFileDeletionFeatureModel(
            files: services.fileOperations,
            hasUnsavedEdits: { [weak self] url in
                self?.openDocuments.contains { document in
                    document.isDirty && (document.url.standardizedFileURL == url.standardizedFileURL
                        || document.url.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/"))
                } == true
            },
            closeCleanDocuments: { [weak self] url in
                guard let self else { return }
                guard !self.openDocuments.contains(where: { $0.isDirty && ($0.url.standardizedFileURL == url.standardizedFileURL
                    || $0.url.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/")) }) else { return }
                self.documentFeature.closeDocuments(containedIn: url)
            }, synchronizeEditors: { [weak self] urls in
                guard let self else { throw CancellationError() }
                let documents = self.openDocuments.filter { document in urls.contains { url in
                    document.url.standardizedFileURL == url.standardizedFileURL
                        || document.url.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/")
                } }
                for document in documents {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        document.withSynchronizedEditor { continuation.resume(with: $0) }
                    }
                    try Task.checkCancellation()
                }
            }, notify: { [weak self] in self?.showNotification($0) })
    }

    func showGitDirectoryDiff(for directoryURL: URL) async {
        let requestID = beginRepositoryDiffRequest(key: RepositoryDiffTabKey(repositoryRoot: gitRepositoryRoot?.standardizedFileURL,
            source: .directory(directoryURL.standardizedFileURL)))
        await performRepositoryDiffRequest(requestID) { await $0.showDirectoryDiff(at: directoryURL, session: $1) }
    }

    func loadGitLineChanges(for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.loadLineChanges(for: fileURL)
    }

    func showGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        let requestID = beginRepositoryDiffRequest(key: workingDiffKey(fileURL))
        await performRepositoryDiffRequest(requestID) { await $0.showLineChange(marker, for: fileURL, session: $1) }
    }

    func stageGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.stageLineChange(marker, for: fileURL)
    }

    func unstageGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.unstageLineChange(marker, for: fileURL)
    }

    func requestDiscardGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        feature.requestDiscardLineChange(marker, for: fileURL)
    }

    func requestConflictRollback(path: String, resume: GitConflictResume) {
        gitFeatureIfActive?.requestConflictRollback(path: path, resume: resume)
    }

    func confirmConflictRollback(_ request: GitConflictRollbackRequest) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmConflictRollback(request)
    }

    func cancelConflictRollback() {
        gitFeatureIfActive?.cancelConflictRollback()
    }

    func showGitConflictDiff(path: String) {
        selectedSidebar = .changes
        gitFeatureIfActive?.clearGitConflictFilter()
        let requestID = beginRepositoryDiffRequest(key: workingDiffKey(gitRepositoryRoot?.appendingPathComponent(path)))
        Task { [weak self] in
            await self?.performRepositoryDiffRequest(requestID) { await $0.selectConflictPath(path, session: $1) }
        }
    }

    func showGitConflictFiles(_ paths: [String]) {
        selectedSidebar = .changes
        gitFeatureIfActive?.setGitConflictFilter(paths)
        if let first = paths.first {
            let requestID = beginRepositoryDiffRequest(key: workingDiffKey(gitRepositoryRoot?.appendingPathComponent(first)))
            Task { [weak self] in
                await self?.performRepositoryDiffRequest(requestID) { await $0.selectConflictPath(first, session: $1) }
            }
        }
    }

    func clearGitConflictFilter() {
        gitFeatureIfActive?.clearGitConflictFilter()
    }

    func selectChange(_ change: GitChange, inNewTab: Bool = false) {
        guard !change.isUntrackedDirectory else { return }
        let requestID = beginRepositoryDiffRequest(key: inNewTab ? nil : RepositoryDiffTabKey(repositoryRoot: change.repositoryRoot.standardizedFileURL,
            source: .workingFile(change.url.standardizedFileURL)))
        Task { [weak self] in
            await self?.performRepositoryDiffRequest(requestID) { await $0.selectChange(change, session: $1) }
        }
    }

    func prepareCommitFiles(_ changes: [GitChange], feature: GitFeatureModel, draft: CommitDraftFeatureModel) {
        let generation = workspaceFeature.workspaceGeneration
        Task { [weak self] in
            guard await feature.prepareCommitFiles(changes), let self,
                  self.workspaceFeature.workspaceGeneration == generation else { return }
            draft.requestCommitEditor()
        }
    }

    func requestDeleteCommitFiles(_ changes: [GitChange], feature: GitFeatureModel) {
        guard let first = changes.first, feature.canRollbackChanges,
              changes.allSatisfy({ feature.gitChanges.contains($0) && $0.repositoryRoot == first.repositoryRoot }) else { return }
        let generation = workspaceFeature.workspaceGeneration
        let root = first.repositoryRoot.standardizedFileURL
        let deletion = commitFileDeletion
        let isCurrent: @MainActor () -> Bool = { [weak self, weak feature] in
            guard let self, let feature else { return false }
            return self.workspaceFeature.workspaceGeneration == generation
                && feature.availableRepositoryRoots.contains(root)
        }
        // Provider roots include ambiguous directories: a nested working copy
        // whose VCS is not chosen yet still must not go to the Trash.
        let isEligible: @MainActor () -> Bool = { [weak self, weak feature] in
            guard let self, let feature, feature.canRollbackChanges,
                  self.vcsProvidersFeature?.isTruncated != true else { return false }
            let nestedRoots = feature.availableRepositoryRoots + (self.vcsProvidersFeature?.knownRootURLs ?? [])
            return changes.allSatisfy { change in
                feature.gitChanges.contains(change)
                    && !VcsProvidersFeatureModel.hasRoot(nestedRoots, atOrBelow: change.url)
            }
        }
        commitFileDeletion.request(changes.map(\.url), root: root,
            isCurrent: isCurrent,
            isEligible: isEligible,
            delete: { [weak self, weak feature, weak deletion] urls in
                guard let self, let feature, let deletion else { return false }
                // Git finds its own nested repositories again below; plugin
                // roots created during the confirmation need a fresh detection.
                if let providers = self.vcsProvidersFeature {
                    guard await providers.confirmRootsAreCurrent(), isCurrent(), isEligible() else {
                        if isCurrent() {
                            self.showNotification(L10n.string("Some selected files belong to another version control root. Refresh and select them again."))
                        }
                        return false
                    }
                }
                return await feature.deleteCommitFiles(changes) {
                    await deletion.trash(urls, root: root, isCurrent: isCurrent)
                }
            }, refresh: { [weak self] in
                await self?.workspaceFeature.refreshCurrent()
            })
    }

    private func workingDiffKey(_ url: URL?) -> RepositoryDiffTabKey? {
        guard let url else { return nil }
        let root = gitChanges.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.repositoryRoot ?? gitRepositoryRoot
        return RepositoryDiffTabKey(repositoryRoot: root?.standardizedFileURL, source: .workingFile(url.standardizedFileURL))
    }

    func refreshGit() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.refreshGit()
    }

    func confirmDiscardHunk(_ request: DiffHunkRequest) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmDiscardHunk(request)
    }

    func cancelDiscardHunk() {
        gitFeatureIfActive?.cancelDiscardHunk()
    }

    func requestDiscardSelectedChange() {
        gitFeatureIfActive?.requestDiscardSelectedChange()
    }

    func requestDiscardChange(_ change: GitChange) {
        gitFeatureIfActive?.requestDiscardChange(change)
    }

    func confirmDiscardChange(_ change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmDiscardChange(change)
    }

    func cancelDiscardChange() {
        gitFeatureIfActive?.cancelDiscardChange()
    }
}
