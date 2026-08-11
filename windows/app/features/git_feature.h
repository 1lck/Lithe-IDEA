#pragma once

#include "dirty_documents_port.h"
#include "git_workflow_types.h"
#include "shelve_service.h"
#include "workbench_coordinator.h"

#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct GitPendingCheckout {
    std::string reference;
    std::string referenceKind;
};

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
    std::optional<GitStashRestoreDto> stashRestoreConflict;
    std::optional<GitPendingCheckout> pendingCheckout;
    std::optional<CoreError> error;

    std::optional<GitCheckoutConflictRequest> pendingCheckoutConflict;
    std::optional<GitIntegrationConflictRequest> pendingIntegrationConflict;
    std::optional<GitPullStrategyRequest> pendingPullStrategy;
    std::optional<GitStashRestoreConflictRequest> pendingStashRestoreConflict;
    std::optional<GitOperationState> operationState;
    std::vector<GitShelfEntry> shelves;
    std::vector<std::string> conflictFilterPaths;
    std::optional<GitDeferredSavedChanges> deferredSavedChanges;
    std::optional<std::string> notifyMessage;
    GitSaveChangesPolicy saveChangesPolicy = GitSaveChangesPolicy::Stash;

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
    bool isPerformingBranchOperation = false;
    bool isResolvingGitOperation = false;
    bool isPerformingShelfOperation = false;
    bool stashRestoreNoticeVisible = false;
};

struct GitStagedDiff {
    std::string path;
    GitDiffDto diff;
};

struct GitShelfPatches {
    std::string stagedPatch;
    std::string workingTreePatch;
};

class GitFeatureModel final {
public:
    using StateHandler = std::function<void(GitFeatureState)>;
    using StagedDiffsHandler = std::function<void(std::vector<GitStagedDiff>,
                                                  std::optional<CoreError>)>;
    using FreezeHandler = std::function<void()>;
    using ShelfPatchesHandler = std::function<void(std::optional<GitShelfPatches>,
                                                   std::optional<CoreError>)>;

    explicit GitFeatureModel(WorkbenchCoordinator& coordinator,
                             DirtyDocumentsPort* dirtyDocuments = nullptr,
                             ShelveService* shelveService = nullptr);

    void setOperationLifecycleHandlers(FreezeHandler began, FreezeHandler ended);
    void setSaveChangesPolicy(GitSaveChangesPolicy policy);
    void setDirtyDocumentsPort(DirtyDocumentsPort* port);
    void setShelveService(ShelveService* service);

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
    void loadShelfPatches(ShelfPatchesHandler handler);
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
    void checkout(std::string reference,
                  std::string referenceKind,
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

    void checkoutReference(std::string fullName,
                           std::string kind,
                           std::string shortName,
                           StateHandler handler = {});
    void resolveCheckoutConflict(GitCheckoutConflictStrategy strategy,
                                 StateHandler handler = {});
    void cancelCheckoutConflict(StateHandler handler = {});

    void mergeReference(std::string fullName,
                        std::string displayName,
                        StateHandler handler = {});
    void rebaseOnto(std::string fullName,
                    std::string displayName,
                    StateHandler handler = {});
    void resolveIntegrationConflict(StateHandler handler = {});
    void cancelIntegrationConflict(StateHandler handler = {});

    void fetch(StateHandler handler = {});
    void push(std::string reference, std::string shortName = {}, StateHandler handler = {});
    void pull(StateHandler handler = {});
    void resolvePullStrategy(GitPullStrategy strategy, StateHandler handler = {});
    void cancelPullStrategy(StateHandler handler = {});

    void commitAndPush(std::string message, bool amend = false, StateHandler handler = {});

    void continueOperation(StateHandler handler = {});
    void abortOperation(StateHandler handler = {});
    void skipOperation(StateHandler handler = {});

    void refreshShelves(StateHandler handler = {});
    void shelveWorkingTree(std::string message, StateHandler handler = {});
    void applyShelf(GitShelfEntry shelf, StateHandler handler = {});
    void dropShelf(GitShelfEntry shelf, StateHandler handler = {});

    void dismissStashRestoreNotice(StateHandler handler = {});
    void showStashRestoreNotice(StateHandler handler = {});
    void setConflictFilterPaths(std::vector<std::string> paths, StateHandler handler = {});
    void clearConflictFilterPaths(StateHandler handler = {});

    void discardConflictPath(std::string path, StateHandler handler = {});
    void retryPendingPreflight(StateHandler handler = {});

    void resetForWorkspace();
    GitFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    DirtyDocumentsPort* dirtyDocuments_ = nullptr;
    ShelveService* shelveService_ = nullptr;
    FreezeHandler onOperationBegan_;
    FreezeHandler onOperationEnded_;
    mutable std::mutex mutex_;
    GitFeatureState state_;
    std::uint32_t operationDepth_ = 0;
    bool refreshStashesOnEnd_ = false;

    void beginOperation();
    void endOperation(StateHandler handler = {}, bool refresh = true);
    void runWrite(GitWriteRequestDto request, StateHandler handler = {});
    void refreshWorkflow(StateHandler handler = {}, bool includeStashes = false);
    void emitState(StateHandler handler);
    void setNotify(std::string message);
    void clearNotify();

    using RepoBlocksHandler =
        std::function<void(bool stale,
                           std::vector<std::string> unmerged,
                           std::vector<std::string> markers,
                           std::optional<CoreError> error)>;
    void collectRepoBlocks(RepoBlocksHandler handler);
    void gateCommitWrite(std::string message, bool amend, bool andPush, StateHandler handler);
    void performCommitAndPush(std::string message, bool amend, StateHandler handler);

    std::vector<std::string> dirtyDocumentPaths() const;
    std::optional<std::string> repositoryRootLocked() const;
    GitSaveChangesPolicy effectiveSavePolicyLocked() const;
    static std::vector<std::string> mergeUniquePaths(std::vector<std::string> left,
                                                     const std::vector<std::string>& right);
    static bool isConflictedChange(const GitChangeDto& change);
    static std::vector<std::string> pathspecsFor(const GitChangeDto& change);
    static std::string trimOutput(const std::string& output);
    static std::string failureMessage(const GitCommandDto& command);
    static std::string joinPaths(const std::vector<std::string>& paths);
    static const char* pullModeId(GitPullStrategy strategy);

    void presentStashRestoreConflictLocked(const GitStashRestoreDto& restore,
                                           std::string operationTitle,
                                           std::optional<std::string> details = std::nullopt);
    void performCheckout(std::string fullName,
                         std::string kind,
                         std::string shortName,
                         bool force,
                         bool autoStash,
                         StateHandler handler);
    void performShelvedCheckout(std::string fullName,
                                std::string kind,
                                std::string shortName,
                                StateHandler handler);
    void startIntegration(std::string reference,
                          std::string displayName,
                          GitIntegrationOperation operation,
                          StateHandler handler);
    void runIntegration(std::string reference,
                        std::string displayName,
                        GitIntegrationOperation operation,
                        StateHandler handler);
    void resolveIntegrationWithStash(GitIntegrationConflictRequest request,
                                     StateHandler handler);
    void resolveIntegrationWithShelf(GitIntegrationConflictRequest request,
                                     StateHandler handler);
    void reportBranchOperation(bool succeeded,
                               std::string successMessage,
                               StateHandler handler);
    void resolveGitOperation(std::string operation, StateHandler handler);
    void restoreDeferredSavedChanges(StateHandler handler);
    void runPull(std::optional<std::string> mode, std::string successMessage, StateHandler handler);

    using ShelfCaptureHandler =
        std::function<void(std::optional<GitShelfEntry>, std::optional<std::string>)>;
    void captureAndCleanShelf(std::string message, ShelfCaptureHandler handler);
    void restoreShelf(GitShelfEntry shelf, std::function<void(bool)> handler);
    void applyPatchChecked(std::string patch,
                           std::string mode,
                           std::string checkMode,
                           std::function<void(bool, std::string)> handler);

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
    void applyPatch(WorkspaceOperationResult result,
                    StateHandler handler,
                    std::uint64_t requestSerial);
    void rebuildConflictFilterPaths();
    std::uint64_t applyRequestSerial_ = 0;
};

} // namespace lithe::windows::app
