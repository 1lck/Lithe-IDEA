import Foundation

extension AppModel {
    func stashWorkingTree(message: String, includeUntracked: Bool) async {
        await gitFeature.stashWorkingTree(message: message, includeUntracked: includeUntracked)
    }

    func shelveWorkingTree(message: String) async {
        await gitFeature.shelveWorkingTree(message: message)
    }

    func applyStash(_ stash: GitStash, pop: Bool = false) async {
        await gitFeature.applyStash(stash, pop: pop)
    }

    func requestConflictRollback(path: String, resume: GitConflictResume) {
        gitFeature.requestConflictRollback(path: path, resume: resume)
    }

    func confirmConflictRollback(_ request: GitConflictRollbackRequest) async {
        await gitFeature.confirmConflictRollback(request)
    }

    func cancelConflictRollback() {
        gitFeature.cancelConflictRollback()
    }

    func showGitConflictDiff(path: String) {
        selectedSidebar = .changes
        gitFeature.clearGitConflictFilter()
        Task { await gitFeature.selectConflictPath(path) }
    }

    func showGitConflictFiles(_ paths: [String]) {
        selectedSidebar = .changes
        gitFeature.setGitConflictFilter(paths)
        if let first = paths.first {
            Task { await gitFeature.selectConflictPath(first) }
        }
    }

    func clearGitConflictFilter() {
        gitFeature.clearGitConflictFilter()
    }

    func showStashRestoreConflictFiles() {
        selectedSidebar = .changes
        gitFeature.showStashRestoreConflictFiles()
    }

    func showStashRestoreConflictStash() {
        selectedSidebar = .changes
        gitFeature.showStashRestoreConflictStash()
    }

    func dismissStashRestoreConflictNotice() {
        gitFeature.dismissStashRestoreConflictNotice()
    }

    func showStashRestoreConflictNotice() {
        gitFeature.showStashRestoreConflictNotice()
    }

    func dropStash(_ stash: GitStash) async {
        await gitFeature.dropStash(stash)
    }

    func applyShelf(_ shelf: GitShelfEntry) async {
        await gitFeature.applyShelf(shelf)
    }

    func dropShelf(_ shelf: GitShelfEntry) async {
        await gitFeature.dropShelf(shelf)
    }
}
