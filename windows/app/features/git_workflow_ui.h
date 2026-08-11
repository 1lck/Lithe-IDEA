#pragma once

#include "core_dto.h"
#include "git_workflow_types.h"

#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

enum class GitCheckoutDialogDecision {
    Cancel,
    Smart,
    Force,
    OpenDiff,
    DiscardAndRetry,
};

enum class GitIntegrationDialogDecision {
    Cancel,
    SaveAndContinue,
    OpenDiff,
    DiscardAndRetry,
};

enum class GitPullDialogDecision {
    Cancel,
    FfOnly,
    Merge,
    Rebase,
};

struct GitOperationBarModel {
    bool visible = false;
    std::string title;
    std::string progress;
    std::vector<std::string> conflictedPaths;
    bool canContinue = false;
    bool canAbort = false;
    bool canSkip = false;
    bool filterActive = false;
};

struct GitStashRestoreNoticeModel {
    bool visible = false;
    std::string stashReference;
    std::vector<std::string> conflictedPaths;
    std::string operationTitle;
};

/// Pure UI decision helpers so Qt widgets and tests share one source of truth.
GitOperationBarModel makeOperationBarModel(const std::optional<GitOperationState>& state,
                                           bool isResolving,
                                           bool filterActive);

GitStashRestoreNoticeModel makeStashRestoreNoticeModel(
    const std::optional<GitStashRestoreConflictRequest>& pending,
    bool noticeVisible);

bool commitBlockedByConflicts(const std::optional<GitStatusDto>& status,
                              const std::vector<std::string>& markerPaths);

std::vector<std::string> filterChangesByConflictPaths(
    const std::vector<GitChangeDto>& changes,
    const std::vector<std::string>& conflictFilterPaths);

bool shouldShowConflictFilterEmptyState(bool filterActive,
                                        std::size_t totalChangeCount,
                                        std::size_t visibleChangeCount);

} // namespace lithe::windows::app
