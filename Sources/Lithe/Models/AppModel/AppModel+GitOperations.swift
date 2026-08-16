import Foundation
import LitheGitModule

extension AppModel {
    func showGitDirectoryDiff(for directoryURL: URL) async {
        activeDocumentID = nil
        guard let feature = await activateGitModule() else { return }
        await feature.showDirectoryDiff(at: directoryURL)
    }

    func loadGitLineChanges(for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.loadLineChanges(for: fileURL)
    }

    func showGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.showLineChange(marker, for: fileURL)
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

    func stashWorkingTree(message: String, includeUntracked: Bool) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stashWorkingTree(message: message, includeUntracked: includeUntracked)
    }

    func shelveWorkingTree(message: String) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.shelveWorkingTree(message: message)
    }

    func applyStash(_ stash: GitStash, pop: Bool = false) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.applyStash(stash, pop: pop)
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
        Task { [weak self] in
            guard let gitFeature = await self?.activateGitModule() else { return }
            await gitFeature.selectConflictPath(path)
        }
    }

    func showGitConflictFiles(_ paths: [String]) {
        selectedSidebar = .changes
        gitFeatureIfActive?.setGitConflictFilter(paths)
        if let first = paths.first {
            Task { [weak self] in
                guard let gitFeature = await self?.activateGitModule() else { return }
                await gitFeature.selectConflictPath(first)
            }
        }
    }

    func clearGitConflictFilter() {
        gitFeatureIfActive?.clearGitConflictFilter()
    }

    func showStashRestoreConflictFiles() {
        selectedSidebar = .changes
        gitFeatureIfActive?.showStashRestoreConflictFiles()
    }

    func showStashRestoreConflictStash() {
        selectedSidebar = .changes
        gitFeatureIfActive?.showStashRestoreConflictStash()
    }

    func dismissStashRestoreConflictNotice() {
        gitFeatureIfActive?.dismissStashRestoreConflictNotice()
    }

    func showStashRestoreConflictNotice() {
        gitFeatureIfActive?.showStashRestoreConflictNotice()
    }

    func dropStash(_ stash: GitStash) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.dropStash(stash)
    }

    func applyShelf(_ shelf: GitShelfEntry) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.applyShelf(shelf)
    }

    func dropShelf(_ shelf: GitShelfEntry) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.dropShelf(shelf)
    }
}
