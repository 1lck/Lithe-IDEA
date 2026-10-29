import Foundation
import LitheGitModule

extension AppModel {
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

    func selectChange(_ change: GitChange) {
        guard !change.isUntrackedDirectory else { return }
        let requestID = beginRepositoryDiffRequest(key: RepositoryDiffTabKey(repositoryRoot: change.repositoryRoot.standardizedFileURL,
            source: .workingFile(change.url.standardizedFileURL)))
        Task { [weak self] in
            await self?.performRepositoryDiffRequest(requestID) { await $0.selectChange(change, session: $1) }
        }
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
