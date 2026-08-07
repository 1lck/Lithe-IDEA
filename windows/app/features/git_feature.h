#pragma once

#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct GitFeatureState {
    std::optional<GitStatusDto> status;
    std::optional<GitDiffDto> diff;
    std::optional<GitHistoryDto> history;
    std::optional<GitCommitLookupDto> commit;
    std::optional<GitFilesResponseDto> commitFiles;
    std::optional<GitComparisonDto> comparison;
    std::optional<GitStashesResponseDto> stashes;
    std::optional<GitBlameResponseDto> blame;
    std::optional<GitCommandDto> command;
    std::optional<GitCheckoutPreflightDto> checkoutPreflight;
    std::optional<GitPullPreflightDto> pullPreflight;
    std::optional<GitIntegrationPreflightDto> integrationPreflight;
    std::optional<GitConflictMarkersDto> conflictMarkers;
    std::optional<GitOperationStateDto> operationState;
    std::optional<GitStashRestoreDto> stashRestoreConflict;
    std::vector<std::string> conflictFilterPaths;
    std::optional<CoreError> error;
    bool isLoadingStatus = false;
    bool isLoadingDiff = false;
    bool isLoadingHistory = false;
    bool isLoadingCommit = false;
    bool isLoadingCommitFiles = false;
    bool isLoadingComparison = false;
    bool isLoadingStashes = false;
    bool isLoadingBlame = false;
    bool isLoadingCheckoutPreflight = false;
    bool isLoadingPullPreflight = false;
    bool isLoadingIntegrationPreflight = false;
    bool isLoadingConflictMarkers = false;
    bool isLoadingOperationState = false;
    bool isWriting = false;
    bool isApplying = false;
};

struct GitStagedDiff {
    std::string path;
    GitDiffDto diff;
};

class GitFeatureModel final {
public:
    using StateHandler = std::function<void(GitFeatureState)>;
    using StagedDiffsHandler = std::function<void(std::vector<GitStagedDiff>,
                                                  std::optional<CoreError>)>;

    explicit GitFeatureModel(WorkbenchCoordinator& coordinator);

    void refreshStatus(StateHandler handler = {});
    void loadDiff(std::vector<std::string> pathspecs,
                  bool staged = false,
                  bool untracked = false,
                  StateHandler handler = {});
    void loadCommitDiff(std::string commit,
                        std::vector<std::string> pathspecs,
                        StateHandler handler = {});
    void loadStagedDiffs(std::vector<std::string> paths,
                         StagedDiffsHandler handler);
    void refreshHistory(std::optional<std::string> reference = std::nullopt,
                        std::uint64_t limit = 300,
                        StateHandler handler = {});
    void loadCommit(std::string commit, StateHandler handler = {});
    void loadCommitFiles(std::string commit, StateHandler handler = {});
    void loadComparison(std::string reference, StateHandler handler = {});
    void refreshStashes(StateHandler handler = {});
    void loadBlame(std::string relativePath, StateHandler handler = {});
    void preflightCheckout(std::string reference, StateHandler handler = {});
    void preflightPull(StateHandler handler = {});
    void preflightIntegration(std::string reference,
                              std::string operation,
                              StateHandler handler = {});
    void refreshConflictMarkers(StateHandler handler = {});
    void refreshOperationState(StateHandler handler = {});
    void clearStashRestoreConflict();
    void write(GitWriteRequestDto request, StateHandler handler = {});
    void runCommand(std::vector<std::string> arguments,
                    std::optional<std::string> input = std::nullopt,
                    StateHandler handler = {});
    void stage(std::vector<std::string> paths, StateHandler handler = {});
    void unstage(std::vector<std::string> paths, StateHandler handler = {});
    void discard(std::vector<std::string> paths, StateHandler handler = {});
    void stageAll(StateHandler handler = {});
    void commit(std::string message, bool amend = false, StateHandler handler = {});
    void stash(std::string message, bool includeUntracked, StateHandler handler = {});
    void applyStash(std::string reference, StateHandler handler = {});
    void popStash(std::string reference, StateHandler handler = {});
    void dropStash(std::string reference, StateHandler handler = {});
    void cloneRepository(std::string remote,
                         std::string destination,
                         std::string parentDirectory,
                         StateHandler handler = {});
    void apply(std::string patch, std::string mode, StateHandler handler = {});
    void resetForWorkspace();
    GitFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    GitFeatureState state_;

    void applyStatus(WorkspaceOperationResult result, StateHandler handler);
    void applyDiff(WorkspaceOperationResult result, StateHandler handler);
    void applyHistory(WorkspaceOperationResult result, StateHandler handler);
    void applyCommit(WorkspaceOperationResult result, StateHandler handler);
    void applyCommitFiles(WorkspaceOperationResult result, StateHandler handler);
    void applyComparison(WorkspaceOperationResult result, StateHandler handler);
    void applyStashes(WorkspaceOperationResult result, StateHandler handler);
    void applyBlame(WorkspaceOperationResult result, StateHandler handler);
    void applyCheckoutPreflight(WorkspaceOperationResult result, StateHandler handler);
    void applyPullPreflight(WorkspaceOperationResult result, StateHandler handler);
    void applyIntegrationPreflight(WorkspaceOperationResult result, StateHandler handler);
    void applyConflictMarkers(WorkspaceOperationResult result, StateHandler handler);
    void applyOperationState(WorkspaceOperationResult result, StateHandler handler);
    void applyWrite(WorkspaceOperationResult result, StateHandler handler);
    void applyPatch(WorkspaceOperationResult result, StateHandler handler);
    void rebuildConflictFilterPaths();
};

} // namespace lithe::windows::app
