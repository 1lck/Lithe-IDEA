#include "git_workflow_ui.h"

#include <algorithm>
#include <unordered_set>

namespace lithe::windows::app {

GitOperationBarModel makeOperationBarModel(const std::optional<GitOperationState>& state,
                                           bool isResolving,
                                           bool filterActive) {
    GitOperationBarModel model;
    if (!state || !state->isActive()) return model;
    model.visible = true;
    if (state->kind == "merge") model.title = "Merge in progress";
    else if (state->kind == "rebase") model.title = "Rebase in progress";
    else if (state->kind == "cherryPick") model.title = "Cherry-pick in progress";
    else if (state->kind == "revert") model.title = "Revert in progress";
    else model.title = "Git operation in progress";
    if (state->step && state->total && *state->total > 0) {
        model.progress = std::to_string(*state->step) + "/" + std::to_string(*state->total);
    }
    model.conflictedPaths = state->conflictedPaths;
    model.canContinue = !isResolving && !state->hasConflicts();
    model.canAbort = !isResolving;
    model.canSkip = !isResolving && state->canSkip();
    model.filterActive = filterActive;
    return model;
}

GitStashRestoreNoticeModel makeStashRestoreNoticeModel(
    const std::optional<GitStashRestoreConflictRequest>& pending,
    bool noticeVisible) {
    GitStashRestoreNoticeModel model;
    if (!pending || !noticeVisible) return model;
    model.visible = true;
    model.stashReference = pending->stashReference;
    model.conflictedPaths = pending->conflictedPaths;
    model.operationTitle = pending->operationTitle;
    return model;
}

bool commitBlockedByConflicts(const std::optional<GitStatusDto>& status,
                              const std::vector<std::string>& markerPaths) {
    if (!markerPaths.empty()) return true;
    if (!status) return false;
    for (const auto& change : status->changes) {
        if (change.status == "U" || change.status == "AA" || change.status == "DD" ||
            change.status == "AU" || change.status == "UA" || change.status == "DU" ||
            change.status == "UD") {
            return true;
        }
    }
    return false;
}

std::vector<std::string> filterChangesByConflictPaths(
    const std::vector<GitChangeDto>& changes,
    const std::vector<std::string>& conflictFilterPaths) {
    if (conflictFilterPaths.empty()) {
        std::vector<std::string> paths;
        paths.reserve(changes.size());
        for (const auto& change : changes) paths.push_back(change.path);
        return paths;
    }
    std::unordered_set<std::string> allowed(conflictFilterPaths.begin(),
                                            conflictFilterPaths.end());
    std::vector<std::string> paths;
    for (const auto& change : changes) {
        if (allowed.contains(change.path)) paths.push_back(change.path);
    }
    return paths;
}

bool shouldShowConflictFilterEmptyState(bool filterActive,
                                        std::size_t totalChangeCount,
                                        std::size_t visibleChangeCount) {
    return filterActive && totalChangeCount > 0 && visibleChangeCount == 0;
}

} // namespace lithe::windows::app
