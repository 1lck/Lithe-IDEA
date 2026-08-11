#include "git_feature.h"

#include <algorithm>
#include <cctype>
#include <memory>
#include <set>
#include <utility>

namespace lithe::windows::app {
namespace {

bool isBlank(const std::string& value) {
    return std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
    });
}

} // namespace

GitFeatureModel::GitFeatureModel(WorkbenchCoordinator& coordinator,
                                 DirtyDocumentsPort* dirtyDocuments,
                                 ShelveService* shelveService)
    : coordinator_(coordinator)
    , dirtyDocuments_(dirtyDocuments)
    , shelveService_(shelveService) {}

void GitFeatureModel::setOperationLifecycleHandlers(FreezeHandler began, FreezeHandler ended) {
    std::lock_guard lock(mutex_);
    onOperationBegan_ = std::move(began);
    onOperationEnded_ = std::move(ended);
}

void GitFeatureModel::setSaveChangesPolicy(GitSaveChangesPolicy policy) {
    std::lock_guard lock(mutex_);
    state_.saveChangesPolicy = policy;
}

void GitFeatureModel::setDirtyDocumentsPort(DirtyDocumentsPort* port) {
    std::lock_guard lock(mutex_);
    dirtyDocuments_ = port;
}

void GitFeatureModel::setShelveService(ShelveService* service) {
    std::lock_guard lock(mutex_);
    shelveService_ = service;
}

void GitFeatureModel::emitState(StateHandler handler) {
    if (handler) handler(state());
}

void GitFeatureModel::setNotify(std::string message) {
    std::lock_guard lock(mutex_);
    state_.notifyMessage = std::move(message);
}

void GitFeatureModel::clearNotify() {
    std::lock_guard lock(mutex_);
    state_.notifyMessage.reset();
}

std::vector<std::string> GitFeatureModel::dirtyDocumentPaths() const {
    if (dirtyDocuments_ == nullptr) return {};
    return dirtyDocuments_->dirtyRelativePaths();
}

std::optional<std::string> GitFeatureModel::repositoryRootLocked() const {
    if (state_.status && state_.status->repositoryRoot &&
        !state_.status->repositoryRoot->empty()) {
        return *state_.status->repositoryRoot;
    }
    return std::nullopt;
}

GitSaveChangesPolicy GitFeatureModel::effectiveSavePolicyLocked() const {
    if (state_.saveChangesPolicy == GitSaveChangesPolicy::Shelve && shelveService_ == nullptr) {
        return GitSaveChangesPolicy::Stash;
    }
    return state_.saveChangesPolicy;
}

std::vector<std::string> GitFeatureModel::mergeUniquePaths(
    std::vector<std::string> left,
    const std::vector<std::string>& right) {
    std::set<std::string> seen(left.begin(), left.end());
    for (const auto& path : right) {
        if (seen.insert(path).second) left.push_back(path);
    }
    return left;
}

bool GitFeatureModel::isConflictedChange(const GitChangeDto& change) {
    if (change.status.size() < 2) return false;
    const char index = change.status[0];
    const char worktree = change.status[1];
    if (index == 'U' || worktree == 'U') return true;
    return (index == 'A' && worktree == 'A') || (index == 'D' && worktree == 'D');
}

std::vector<std::string> GitFeatureModel::pathspecsFor(const GitChangeDto& change) {
    if (change.originalPath && *change.originalPath != change.path) {
        return {*change.originalPath, change.path};
    }
    return {change.path};
}

std::string GitFeatureModel::trimOutput(const std::string& output) {
    std::size_t begin = 0;
    while (begin < output.size() &&
           (output[begin] == ' ' || output[begin] == '\t' ||
            output[begin] == '\n' || output[begin] == '\r')) {
        ++begin;
    }
    std::size_t end = output.size();
    while (end > begin &&
           (output[end - 1] == ' ' || output[end - 1] == '\t' ||
            output[end - 1] == '\n' || output[end - 1] == '\r')) {
        --end;
    }
    return output.substr(begin, end - begin);
}

std::string GitFeatureModel::failureMessage(const GitCommandDto& command) {
    const auto message = trimOutput(command.output);
    return message.empty() ? "Git operation failed" : message;
}

std::string GitFeatureModel::joinPaths(const std::vector<std::string>& paths) {
    std::string joined;
    for (std::size_t i = 0; i < paths.size(); ++i) {
        if (i > 0) joined += ", ";
        joined += paths[i];
    }
    return joined;
}

void GitFeatureModel::collectRepoBlocks(RepoBlocksHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingStatus = true;
        state_.error.reset();
    }
    coordinator_.gitStatus([this, handler = std::move(handler)](
                               WorkspaceOperationResult statusResult) mutable {
        if (statusResult.stale) {
            {
                std::lock_guard lock(mutex_);
                state_.isLoadingStatus = false;
            }
            if (handler) handler(true, {}, {}, std::nullopt);
            return;
        }
        applyStatus(statusResult, {});
        std::vector<std::string> unmerged;
        std::optional<CoreError> statusError;
        {
            std::lock_guard lock(mutex_);
            statusError = state_.error;
            if (!statusError && state_.status) {
                for (const auto& change : state_.status->changes) {
                    if (isConflictedChange(change)) unmerged.push_back(change.path);
                }
            }
        }
        if (statusError) {
            if (handler) handler(false, {}, {}, std::move(statusError));
            return;
        }
        coordinator_.gitConflictMarkers(
            [this, unmerged = std::move(unmerged), handler = std::move(handler)](
                WorkspaceOperationResult markersResult) mutable {
                if (markersResult.stale) {
                    if (handler) handler(true, {}, {}, std::nullopt);
                    return;
                }
                if (!markersResult.envelope || !markersResult.envelope->ok) {
                    if (handler) {
                        handler(false, std::move(unmerged), {}, markersResult.coreError());
                    }
                    return;
                }
                auto dto = decodeGitConflictMarkers(*markersResult.envelope);
                if (!dto) {
                    if (handler) {
                        handler(false, std::move(unmerged), {},
                                CoreError{CoreErrorCode::ParseFailed,
                                          "Invalid Git conflict markers response",
                                          std::nullopt});
                    }
                    return;
                }
                if (handler) {
                    handler(false, std::move(unmerged), std::move(dto->paths), std::nullopt);
                }
            });
    });
}

const char* GitFeatureModel::pullModeId(GitPullStrategy strategy) {
    switch (strategy) {
    case GitPullStrategy::FfOnly: return "ffOnly";
    case GitPullStrategy::Merge: return "merge";
    case GitPullStrategy::Rebase: return "rebase";
    }
    return "ffOnly";
}

void GitFeatureModel::beginOperation() {
    FreezeHandler began;
    {
        std::lock_guard lock(mutex_);
        ++operationDepth_;
        if (operationDepth_ == 1) began = onOperationBegan_;
    }
    if (began) began();
}

void GitFeatureModel::endOperation(StateHandler handler, bool refresh) {
    FreezeHandler ended;
    bool outermost = false;
    bool includeStashes = false;
    {
        std::lock_guard lock(mutex_);
        if (operationDepth_ > 0) --operationDepth_;
        outermost = operationDepth_ == 0;
        if (outermost) {
            ended = onOperationEnded_;
            includeStashes = refreshStashesOnEnd_;
            refreshStashesOnEnd_ = false;
        }
    }
    if (!outermost) {
        emitState(std::move(handler));
        return;
    }
    if (!refresh) {
        if (ended) ended();
        emitState(std::move(handler));
        return;
    }
    // Refresh while the watcher is still frozen, then flush — matches macOS
    // withGitOperation (refreshGit before endGitOperationFreeze). Ending freeze
    // first races Abort/merge cleanup against loadSnapshot and caused Debug CRT
    // breakpoint crashes (ucrtbased 0x80000003) on the Abort confirm path.
    refreshWorkflow(
        [ended = std::move(ended), handler = std::move(handler)](GitFeatureState state) mutable {
            if (ended) ended();
            if (handler) handler(std::move(state));
        },
        includeStashes);
}

void GitFeatureModel::refreshWorkflow(StateHandler handler, bool includeStashes) {
    std::optional<CoreError> preservedError;
    std::optional<GitCommandDto> preservedCommand;
    std::optional<std::string> preservedNotify;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingStatus = true;
        preservedError = state_.error;
        preservedCommand = state_.command;
        preservedNotify = state_.notifyMessage;
    }
    coordinator_.gitStatus([this, handler = std::move(handler), includeStashes,
                            preservedError = std::move(preservedError),
                            preservedCommand = std::move(preservedCommand),
                            preservedNotify = std::move(preservedNotify)](
                               WorkspaceOperationResult statusResult) mutable {
        if (statusResult.stale) {
            {
                std::lock_guard lock(mutex_);
                state_.isLoadingStatus = false;
                if (preservedError) state_.error = std::move(preservedError);
                if (preservedCommand) state_.command = std::move(preservedCommand);
                if (preservedNotify) state_.notifyMessage = std::move(preservedNotify);
            }
            emitState(std::move(handler));
            return;
        }
        applyStatus(std::move(statusResult), {});
        coordinator_.gitOperationState(
            [this, handler = std::move(handler), includeStashes,
             preservedError = std::move(preservedError),
             preservedCommand = std::move(preservedCommand),
             preservedNotify = std::move(preservedNotify)](
                WorkspaceOperationResult opResult) mutable {
                if (!opResult.stale) {
                    std::lock_guard lock(mutex_);
                    if (opResult.envelope && opResult.envelope->ok) {
                        if (auto dto = decodeGitOperationState(*opResult.envelope)) {
                            state_.operationState = toOperationState(*dto);
                        }
                    }
                }
                auto finish = [this, handler = std::move(handler),
                               preservedError = std::move(preservedError),
                               preservedCommand = std::move(preservedCommand),
                               preservedNotify = std::move(preservedNotify)]() mutable {
                    {
                        std::lock_guard lock(mutex_);
                        if (preservedError) state_.error = std::move(*preservedError);
                        if (preservedCommand) state_.command = std::move(*preservedCommand);
                        if (preservedNotify) state_.notifyMessage = std::move(*preservedNotify);
                    }
                    emitState(std::move(handler));
                };
                if (!includeStashes) {
                    finish();
                    return;
                }
                {
                    std::lock_guard lock(mutex_);
                    state_.isLoadingStashes = true;
                }
                coordinator_.gitStashes(
                    [this, finish = std::move(finish)](WorkspaceOperationResult stashResult) mutable {
                        applyStashes(std::move(stashResult), {});
                        finish();
                    });
            });
    });
}

void GitFeatureModel::runWrite(GitWriteRequestDto request, StateHandler handler) {
    beginOperation();
    {
        std::lock_guard lock(mutex_);
        state_.isWriting = true;
        state_.error.reset();
        state_.notifyMessage.reset();
        const auto& op = request.operation;
        if (op == "stashPush" || op == "stashApply" || op == "stashPop" ||
            op == "stashDrop" || op == "checkout") {
            refreshStashesOnEnd_ = true;
        }
    }
    coordinator_.gitWrite(std::move(request),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyWrite(std::move(result), {});
            endOperation(std::move(handler), true);
        });
}

void GitFeatureModel::presentStashRestoreConflictLocked(const GitStashRestoreDto& restore,
                                                        std::string operationTitle,
                                                        std::optional<std::string> details) {
    state_.pendingStashRestoreConflict = GitStashRestoreConflictRequest{
        restore.stashReference,
        restore.conflictedPaths,
        std::move(operationTitle),
    };
    state_.stashRestoreNoticeVisible = true;
    state_.error = CoreError{
        CoreErrorCode::ProcessFailed,
        "Stash restore left conflicts",
        std::move(details),
    };
}

void GitFeatureModel::refreshStatus(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.error.reset();
    }
    // Match macOS refreshGit: status alone is not enough for Continue/Abort/Skip.
    // Rebase/merge markers live in operationState; Refresh must refresh both.
    refreshWorkflow(std::move(handler), false);
}

void GitFeatureModel::loadDiff(std::vector<std::string> pathspecs,
                               bool staged,
                               bool untracked,
                               StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingDiff = true;
        state_.error.reset();
    }
    coordinator_.gitDiff(std::move(pathspecs), staged, untracked,
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyDiff(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::loadCommitDiff(std::string commit,
                                     std::vector<std::string> pathspecs,
                                     StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingDiff = true;
        state_.error.reset();
    }
    coordinator_.gitCommitDiff(std::move(commit), std::move(pathspecs),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyDiff(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::loadStagedDiffs(std::vector<std::string> paths,
                                      StagedDiffsHandler handler) {
    struct CollectionState {
        std::vector<std::string> paths;
        std::size_t index = 0;
        std::vector<GitStagedDiff> diffs;
        StagedDiffsHandler handler;
        std::function<void()> next;
    };

    auto state = std::make_shared<CollectionState>();
    state->paths = std::move(paths);
    state->handler = std::move(handler);
    state->next = [this, state] {
        if (state->index >= state->paths.size()) {
            auto completed = std::move(state->handler);
            auto diffs = std::move(state->diffs);
            state->next = {};
            if (completed) completed(std::move(diffs), std::nullopt);
            return;
        }

        const auto path = state->paths[state->index];
        coordinator_.gitDiff({path}, true, false,
            [state, path](WorkspaceOperationResult result) mutable {
                auto fail = [state](CoreError error) {
                    auto completed = std::move(state->handler);
                    state->next = {};
                    if (completed) completed({}, std::move(error));
                };
                if (result.stale) {
                    fail(CoreError{CoreErrorCode::Cancelled,
                                   "Staged diff request became stale", std::nullopt});
                    return;
                }
                if (!result.envelope || !result.envelope->ok) {
                    if (const auto error = result.coreError()) {
                        fail(*error);
                    } else {
                        fail(CoreError{CoreErrorCode::Unknown, "Staged diff failed", std::nullopt});
                    }
                    return;
                }
                const auto diff = decodeGitDiff(*result.envelope);
                if (!diff) {
                    fail(CoreError{CoreErrorCode::ParseFailed,
                                   "Invalid staged diff response", std::nullopt});
                    return;
                }
                state->diffs.push_back({path, *diff});
                ++state->index;
                state->next();
            });
    };
    state->next();
}

void GitFeatureModel::loadShelfPatches(ShelfPatchesHandler handler) {
    coordinator_.gitShelfPatches([handler = std::move(handler)](
                                      WorkspaceOperationResult result) mutable {
        if (result.stale) {
            if (handler) handler(std::nullopt, CoreError{
                CoreErrorCode::Cancelled, "Shelf patch request became stale", std::nullopt});
            return;
        }
        if (!result.envelope || !result.envelope->ok) {
            if (handler) {
                if (const auto error = result.coreError()) {
                    handler(std::nullopt, *error);
                } else {
                    handler(std::nullopt, CoreError{
                        CoreErrorCode::Unknown, "Shelf patch request failed", std::nullopt});
                }
            }
            return;
        }
        const auto patches = decodeGitShelfPatches(*result.envelope);
        if (handler) {
            if (patches) {
                handler(GitShelfPatches{patches->stagedPatch, patches->workingTreePatch},
                        std::nullopt);
            } else {
                handler(std::nullopt, CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Shelf patch response", std::nullopt});
            }
        }
    });
}

void GitFeatureModel::refreshHistory(std::optional<std::string> reference,
                                     std::uint64_t limit,
                                     StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingHistory = true;
        state_.history.reset();
        state_.error.reset();
    }
    coordinator_.gitHistory(std::move(reference), limit,
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyHistory(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::loadCommit(std::string commit, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommit = true;
        state_.commit.reset();
        state_.commitFiles.reset();
        state_.comparison.reset();
        state_.error.reset();
    }
    coordinator_.gitCommit(std::move(commit),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyCommit(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::loadCommitFiles(std::string commit, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommitFiles = true;
        state_.commitFiles.reset();
        state_.error.reset();
    }
    coordinator_.gitCommitFiles(std::move(commit),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyCommitFiles(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::loadComparison(std::string reference, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingComparison = true;
        state_.comparison.reset();
        state_.commit.reset();
        state_.commitFiles.reset();
        state_.error.reset();
    }
    coordinator_.gitComparison(std::move(reference),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyComparison(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::refreshStashes(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingStashes = true;
        state_.stashes.reset();
        state_.error.reset();
    }
    coordinator_.gitStashes(
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyStashes(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::loadBlame(std::string relativePath, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingBlame = true;
        state_.error.reset();
    }
    coordinator_.gitBlame(std::move(relativePath),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyBlame(std::move(result), std::move(handler));
        });
}

void GitFeatureModel::preflightCheckout(std::string reference, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingCheckoutPreflight = true;
        state_.checkoutPreflight.reset();
        state_.error.reset();
    }
    coordinator_.gitCheckoutPreflight(std::move(reference),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyCheckoutPreflight(std::move(result), std::move(handler));
    });
}

void GitFeatureModel::preflightPull(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingPullPreflight = true;
        state_.pullPreflight.reset();
        state_.error.reset();
    }
    coordinator_.gitPullPreflight(
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyPullPreflight(std::move(result), std::move(handler));
    });
}

void GitFeatureModel::preflightIntegration(std::string reference,
                                           std::string operation,
                                           StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingIntegrationPreflight = true;
        state_.integrationPreflight.reset();
        state_.error.reset();
    }
    coordinator_.gitIntegrationPreflight(std::move(reference), std::move(operation),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyIntegrationPreflight(std::move(result), std::move(handler));
    });
}

void GitFeatureModel::checkout(std::string reference,
                               std::string referenceKind,
                               StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.pendingCheckout = GitPendingCheckout{reference, referenceKind};
    }
    const auto preflightReference = reference;
    preflightCheckout(preflightReference, [this,
                                  reference = std::move(reference),
                                  referenceKind = std::move(referenceKind),
                                  handler = std::move(handler)](GitFeatureState state) mutable {
        if (state.error || state.isLoadingCheckoutPreflight ||
            !state.checkoutPreflight || !state.checkoutPreflight->blockingPaths.empty()) {
            {
                std::lock_guard lock(mutex_);
                state_.pendingCheckout.reset();
            }
            state.pendingCheckout.reset();
            if (handler) handler(std::move(state));
            return;
        }
        GitWriteRequestDto request;
        request.operation = "checkout";
        request.reference = std::move(reference);
        request.referenceKind = std::move(referenceKind);
        write(std::move(request),
              [this, handler = std::move(handler)](GitFeatureState result) mutable {
                  {
                      std::lock_guard lock(mutex_);
                      state_.pendingCheckout.reset();
                  }
                  result.pendingCheckout.reset();
                  if (handler) handler(std::move(result));
              });
    });
}

void GitFeatureModel::refreshConflictMarkers(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingConflictMarkers = true;
        state_.conflictMarkers.reset();
        state_.error.reset();
    }
    coordinator_.gitConflictMarkers(
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyConflictMarkers(std::move(result), std::move(handler));
    });
}

void GitFeatureModel::refreshOperationState(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingOperationState = true;
        state_.error.reset();
    }
    coordinator_.gitOperationState(
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyOperationState(std::move(result), std::move(handler));
    });
}

void GitFeatureModel::clearStashRestoreConflict() {
    std::lock_guard lock(mutex_);
    state_.stashRestoreConflict.reset();
    rebuildConflictFilterPaths();
}

void GitFeatureModel::write(GitWriteRequestDto request, StateHandler handler) {
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::runCommand(std::vector<std::string> arguments,
                                 std::optional<std::string> input,
                                 StateHandler handler) {
    beginOperation();
    {
        std::lock_guard lock(mutex_);
        state_.isWriting = true;
        state_.error.reset();
    }
    coordinator_.gitCommand(GitCommandRequestDto{{}, std::move(arguments), std::move(input)},
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyWrite(std::move(result), {});
            endOperation(std::move(handler), true);
        });
}

void GitFeatureModel::stage(std::vector<std::string> paths, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stage";
    request.paths = std::move(paths);
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::unstage(std::vector<std::string> paths, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "unstage";
    request.paths = std::move(paths);
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::discard(std::vector<std::string> paths, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "discard";
    request.paths = std::move(paths);
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::stageAll(StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stageAll";
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::commit(std::string message, bool amend, StateHandler handler) {
    gateCommitWrite(std::move(message), amend, false, std::move(handler));
}

void GitFeatureModel::gateCommitWrite(std::string message,
                                      bool amend,
                                      bool andPush,
                                      StateHandler handler) {
    collectRepoBlocks(
        [this, message = std::move(message), amend, andPush,
         handler = std::move(handler)](bool stale,
                                       std::vector<std::string> unmerged,
                                       std::vector<std::string> markers,
                                       std::optional<CoreError> error) mutable {
            if (stale) {
                emitState(std::move(handler));
                return;
            }
            if (error) {
                {
                    std::lock_guard lock(mutex_);
                    state_.error = std::move(*error);
                }
                emitState(std::move(handler));
                return;
            }
            if (!unmerged.empty()) {
                setNotify("Resolve the conflicts first: " + joinPaths(unmerged));
                emitState(std::move(handler));
                return;
            }
            if (!markers.empty()) {
                setNotify("Conflict markers remain in: " + joinPaths(markers));
                emitState(std::move(handler));
                return;
            }
            if (andPush) {
                performCommitAndPush(std::move(message), amend, std::move(handler));
                return;
            }
            GitWriteRequestDto request;
            request.operation = "commit";
            request.message = std::move(message);
            request.amend = amend;
            runWrite(std::move(request), std::move(handler));
        });
}

void GitFeatureModel::stash(std::string message,
                            bool includeUntracked,
                            StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashPush";
    request.message = std::move(message);
    request.includeUntracked = includeUntracked;
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::applyStash(std::string reference, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashApply";
    request.reference = std::move(reference);
    runWrite(std::move(request), [this, handler = std::move(handler)](GitFeatureState state) {
        if (state.pendingStashRestoreConflict) {
            // Conflict already surfaced; keep error semantics.
        } else if (!state.error) {
            setNotify("Applied stash");
        }
        emitState(std::move(handler));
    });
}

void GitFeatureModel::popStash(std::string reference, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashPop";
    request.reference = std::move(reference);
    runWrite(std::move(request), [this, handler = std::move(handler)](GitFeatureState state) {
        if (!state.pendingStashRestoreConflict && !state.error) {
            setNotify("Popped stash");
        }
        emitState(std::move(handler));
    });
}

void GitFeatureModel::dropStash(std::string reference, StateHandler handler) {
    auto stashRef = reference;
    GitWriteRequestDto request;
    request.operation = "stashDrop";
    request.reference = std::move(reference);
    runWrite(std::move(request),
        [this, stashRef = std::move(stashRef), handler = std::move(handler)](
            GitFeatureState state) {
            if (!state.error) {
                std::lock_guard lock(mutex_);
                if (state_.pendingStashRestoreConflict &&
                    state_.pendingStashRestoreConflict->stashReference == stashRef) {
                    state_.pendingStashRestoreConflict.reset();
                    state_.stashRestoreNoticeVisible = false;
                }
                state_.notifyMessage = "Dropped stash";
            }
            emitState(std::move(handler));
        });
}

void GitFeatureModel::cloneRepository(std::string remote,
                                      std::string destination,
                                      std::string parentDirectory,
                                      StateHandler handler) {
    GitWriteRequestDto request;
    request.root = std::move(parentDirectory);
    request.operation = "clone";
    request.remote = std::move(remote);
    request.destination = std::move(destination);
    runWrite(std::move(request), std::move(handler));
}

void GitFeatureModel::apply(std::string patch, std::string mode, StateHandler handler) {
    beginOperation();
    const auto requestSerial = ++applyRequestSerial_;
    {
        std::lock_guard lock(mutex_);
        state_.isApplying = true;
        state_.error.reset();
    }
    coordinator_.gitApply(std::move(patch), std::move(mode),
        [this, handler = std::move(handler), requestSerial](WorkspaceOperationResult result) mutable {
            applyPatch(std::move(result), {}, requestSerial);
            endOperation(std::move(handler), true);
        });
}

void GitFeatureModel::checkoutReference(std::string fullName,
                                        std::string kind,
                                        std::string shortName,
                                        StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
        state_.notifyMessage.reset();
        state_.error.reset();
        state_.pendingCheckoutConflict.reset();
    }
    auto dirty = dirtyDocumentPaths();
    collectRepoBlocks(
        [this, fullName = std::move(fullName), kind = std::move(kind),
         shortName = std::move(shortName), dirty = std::move(dirty),
         handler = std::move(handler)](bool stale,
                                       std::vector<std::string> unmerged,
                                       std::vector<std::string> markers,
                                       std::optional<CoreError> error) mutable {
            if (stale) {
                {
                    std::lock_guard lock(mutex_);
                    state_.isPerformingBranchOperation = false;
                }
                emitState(std::move(handler));
                return;
            }
            if (error) {
                {
                    std::lock_guard lock(mutex_);
                    state_.isPerformingBranchOperation = false;
                    state_.error = std::move(*error);
                }
                emitState(std::move(handler));
                return;
            }
            auto repoBlocking = mergeUniquePaths(std::move(unmerged), markers);
            coordinator_.gitCheckoutPreflight(fullName,
                [this, fullName, kind, shortName, dirty = std::move(dirty),
                 repoBlocking = std::move(repoBlocking),
                 handler = std::move(handler)](WorkspaceOperationResult result) mutable {
                    if (result.stale) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    std::vector<std::string> blocking;
                    if (result.envelope && result.envelope->ok) {
                        if (auto dto = decodeGitCheckoutPreflight(*result.envelope)) {
                            blocking = std::move(dto->blockingPaths);
                        }
                    } else if (const auto coreError = result.coreError()) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            state_.error = *coreError;
                        }
                        emitState(std::move(handler));
                        return;
                    }

                    auto merged = mergeUniquePaths(std::move(blocking), repoBlocking);
                    merged = mergeUniquePaths(std::move(merged), dirty);
                    if (!merged.empty() || !dirty.empty()) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            state_.pendingCheckoutConflict = GitCheckoutConflictRequest{
                                fullName, kind, shortName, std::move(merged),
                                std::move(dirty)};
                        }
                        emitState(std::move(handler));
                        return;
                    }

                    {
                        std::lock_guard lock(mutex_);
                        state_.isPerformingBranchOperation = false;
                    }
                    performCheckout(std::move(fullName), std::move(kind), std::move(shortName),
                                    false, false, std::move(handler));
                });
        });
}

void GitFeatureModel::resolveCheckoutConflict(GitCheckoutConflictStrategy strategy,
                                              StateHandler handler) {
    GitCheckoutConflictRequest pending;
    {
        std::lock_guard lock(mutex_);
        if (!state_.pendingCheckoutConflict) {
            state_.notifyMessage = "No checkout conflict to resolve";
            emitState(std::move(handler));
            return;
        }
        pending = *state_.pendingCheckoutConflict;
        state_.pendingCheckoutConflict.reset();
    }
    switch (strategy) {
    case GitCheckoutConflictStrategy::Smart:
        performCheckout(std::move(pending.reference), std::move(pending.referenceKind),
                        std::move(pending.shortName), false, true, std::move(handler));
        break;
    case GitCheckoutConflictStrategy::Force:
        performCheckout(std::move(pending.reference), std::move(pending.referenceKind),
                        std::move(pending.shortName), true, false, std::move(handler));
        break;
    }
}

void GitFeatureModel::cancelCheckoutConflict(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.pendingCheckoutConflict.reset();
    }
    emitState(std::move(handler));
}

void GitFeatureModel::performCheckout(std::string fullName,
                                      std::string kind,
                                      std::string shortName,
                                      bool force,
                                      bool autoStash,
                                      StateHandler handler) {
    if (autoStash) {
        GitSaveChangesPolicy policy;
        {
            std::lock_guard lock(mutex_);
            policy = effectiveSavePolicyLocked();
        }
        if (policy == GitSaveChangesPolicy::Shelve) {
            performShelvedCheckout(std::move(fullName), std::move(kind), std::move(shortName),
                                   std::move(handler));
            return;
        }
    }

    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    GitWriteRequestDto request;
    request.operation = "checkout";
    request.reference = std::move(fullName);
    request.referenceKind = std::move(kind);
    request.force = force;
    request.autoStash = autoStash;
    const auto name = shortName;
    runWrite(std::move(request),
        [this, name, force, autoStash, handler = std::move(handler)](GitFeatureState state) {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
            }
            if (state.pendingStashRestoreConflict) {
                emitState(std::move(handler));
                return;
            }
            if (!state.error) {
                if (autoStash) {
                    setNotify("Checked out " + name + " and restored local changes");
                } else if (force) {
                    setNotify("Checked out " + name + ", discarding local changes");
                } else {
                    setNotify("Checked out " + name);
                }
            } else if (autoStash) {
                // Branch may have switched even when restore failed.
            }
            emitState(std::move(handler));
        });
}

void GitFeatureModel::performShelvedCheckout(std::string fullName,
                                             std::string kind,
                                             std::string shortName,
                                             StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        if (shelveService_ == nullptr) {
            // Fall back to stash-based smart checkout.
        } else {
            state_.isPerformingBranchOperation = true;
        }
    }
    if (shelveService_ == nullptr) {
        performCheckout(std::move(fullName), std::move(kind), std::move(shortName),
                        false, true, std::move(handler));
        return;
    }

    beginOperation();
    captureAndCleanShelf("Lithe shelf before checkout",
        [this, fullName = std::move(fullName), kind = std::move(kind),
         shortName = std::move(shortName),
         handler = std::move(handler)](std::optional<GitShelfEntry> shelf,
                                       std::optional<std::string> error) mutable {
            if (!shelf) {
                {
                    std::lock_guard lock(mutex_);
                    state_.isPerformingBranchOperation = false;
                    if (error) state_.notifyMessage = *error;
                }
                endOperation(std::move(handler), true);
                return;
            }
            GitWriteRequestDto request;
            request.operation = "checkout";
            request.reference = fullName;
            request.referenceKind = kind;
            runWrite(std::move(request),
                [this, shelf = std::move(*shelf), shortName = std::move(shortName),
                 handler = std::move(handler)](GitFeatureState state) mutable {
                    if (state.error) {
                        restoreShelf(std::move(shelf),
                            [this, handler = std::move(handler)](bool) mutable {
                                {
                                    std::lock_guard lock(mutex_);
                                    state_.isPerformingBranchOperation = false;
                                }
                                endOperation(std::move(handler), true);
                            });
                        return;
                    }
                    {
                        std::lock_guard lock(mutex_);
                        state_.isPerformingShelfOperation = true;
                    }
                    restoreShelf(std::move(shelf),
                        [this, shortName = std::move(shortName),
                         handler = std::move(handler)](bool restored) mutable {
                            {
                                std::lock_guard lock(mutex_);
                                state_.isPerformingShelfOperation = false;
                                state_.isPerformingBranchOperation = false;
                                if (restored) {
                                    state_.notifyMessage =
                                        "Checked out " + shortName +
                                        " and restored shelved changes";
                                }
                            }
                            endOperation(std::move(handler), true);
                        });
                });
        });
}

void GitFeatureModel::mergeReference(std::string fullName,
                                     std::string displayName,
                                     StateHandler handler) {
    startIntegration(std::move(fullName), std::move(displayName),
                     GitIntegrationOperation::Merge, std::move(handler));
}

void GitFeatureModel::rebaseOnto(std::string fullName,
                                 std::string displayName,
                                 StateHandler handler) {
    startIntegration(std::move(fullName), std::move(displayName),
                     GitIntegrationOperation::Rebase, std::move(handler));
}

void GitFeatureModel::startIntegration(std::string reference,
                                       std::string displayName,
                                       GitIntegrationOperation operation,
                                       StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.pendingIntegrationConflict.reset();
        state_.notifyMessage.reset();
        state_.error.reset();
    }
    auto dirty = dirtyDocumentPaths();
    const auto operationId = std::string(integrationOperationId(operation));
    collectRepoBlocks(
        [this, reference = std::move(reference), displayName = std::move(displayName),
         operation, dirty = std::move(dirty), operationId,
         handler = std::move(handler)](bool stale,
                                       std::vector<std::string> unmerged,
                                       std::vector<std::string> markers,
                                       std::optional<CoreError> error) mutable {
            if (stale) {
                emitState(std::move(handler));
                return;
            }
            if (error) {
                {
                    std::lock_guard lock(mutex_);
                    state_.error = std::move(*error);
                }
                emitState(std::move(handler));
                return;
            }
            auto repoBlocking = mergeUniquePaths(std::move(unmerged), markers);
            const bool repoBlocksEntirely = !repoBlocking.empty();
            coordinator_.gitIntegrationPreflight(reference, operationId,
                [this, reference, displayName, operation, dirty = std::move(dirty),
                 repoBlocking = std::move(repoBlocking), repoBlocksEntirely,
                 handler = std::move(handler)](WorkspaceOperationResult result) mutable {
                    if (result.stale) {
                        emitState(std::move(handler));
                        return;
                    }
                    std::vector<std::string> blocking;
                    bool blocksEntirely = false;
                    if (result.envelope && result.envelope->ok) {
                        if (auto dto = decodeGitIntegrationPreflight(*result.envelope)) {
                            blocking = std::move(dto->blockingPaths);
                            blocksEntirely = dto->blocksEntirely;
                        }
                    } else if (const auto coreError = result.coreError()) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.error = *coreError;
                        }
                        emitState(std::move(handler));
                        return;
                    }

                    auto merged = mergeUniquePaths(std::move(blocking), repoBlocking);
                    merged = mergeUniquePaths(std::move(merged), dirty);
                    blocksEntirely = blocksEntirely || repoBlocksEntirely || !dirty.empty();
                    if (!merged.empty() || !dirty.empty() || blocksEntirely) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.pendingIntegrationConflict = GitIntegrationConflictRequest{
                                reference,
                                displayName,
                                operation,
                                std::move(merged),
                                blocksEntirely,
                                std::move(dirty),
                            };
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    runIntegration(std::move(reference), std::move(displayName), operation,
                                   std::move(handler));
                });
        });
}

void GitFeatureModel::runIntegration(std::string reference,
                                     std::string displayName,
                                     GitIntegrationOperation operation,
                                     StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    GitWriteRequestDto request;
    request.operation = integrationOperationId(operation);
    request.reference = std::move(reference);
    std::string success;
    switch (operation) {
    case GitIntegrationOperation::Merge:
        success = "Merged " + displayName;
        break;
    case GitIntegrationOperation::Rebase:
        success = "Rebased onto " + displayName;
        break;
    case GitIntegrationOperation::CherryPick:
        success = "Cherry-picked " + displayName;
        break;
    case GitIntegrationOperation::Revert:
        success = "Reverted " + displayName;
        break;
    }
    runWrite(std::move(request),
        [this, success = std::move(success), handler = std::move(handler)](GitFeatureState state) {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
            }
            reportBranchOperation(!state.error, std::move(success), std::move(handler));
        });
}

void GitFeatureModel::reportBranchOperation(bool succeeded,
                                            std::string successMessage,
                                            StateHandler handler) {
    auto publish = [this, succeeded, successMessage = std::move(successMessage),
                    handler = std::move(handler)](GitFeatureState) mutable {
        {
            std::lock_guard lock(mutex_);
            if (state_.operationState && state_.operationState->isActive()) {
                // Conflict exits are expected; do not keep a generic ProcessFailed
                // error that races the operation bar / status-line UX.
                if (state_.error &&
                    state_.error->code == CoreErrorCode::ProcessFailed &&
                    state_.error->message == "Git command failed") {
                    state_.error.reset();
                }
                if (state_.operationState->hasConflicts()) {
                    state_.notifyMessage =
                        state_.operationState->kind + " stopped with " +
                        std::to_string(state_.operationState->conflictedPaths.size()) +
                        " conflicted file(s)";
                } else if (succeeded) {
                    state_.notifyMessage = std::move(successMessage);
                }
            } else if (succeeded) {
                state_.notifyMessage = std::move(successMessage);
            }
        }
        emitState(std::move(handler));
    };

    bool needsOperationState = false;
    {
        std::lock_guard lock(mutex_);
        if (!state_.operationState || !state_.operationState->isActive()) {
            if (!succeeded) {
                needsOperationState = true;
            } else if (state_.status) {
                for (const auto& change : state_.status->changes) {
                    if (isConflictedChange(change)) {
                        needsOperationState = true;
                        break;
                    }
                }
            }
        }
    }
    if (needsOperationState) {
        // runWrite already refreshed once; if markers were not visible yet (seen
        // with rebase on Windows), fetch operationState again before publishing.
        refreshWorkflow(std::move(publish), true);
        return;
    }
    publish({});
}

void GitFeatureModel::resolveIntegrationConflict(StateHandler handler) {
    GitIntegrationConflictRequest request;
    GitSaveChangesPolicy policy;
    {
        std::lock_guard lock(mutex_);
        if (!state_.pendingIntegrationConflict) {
            state_.notifyMessage = "No integration conflict to resolve";
            emitState(std::move(handler));
            return;
        }
        request = *state_.pendingIntegrationConflict;
        state_.pendingIntegrationConflict.reset();
        policy = effectiveSavePolicyLocked();
    }
    beginOperation();
    auto finish = [this, handler = std::move(handler)](GitFeatureState) mutable {
        endOperation(std::move(handler), true);
    };
    if (policy == GitSaveChangesPolicy::Shelve) {
        resolveIntegrationWithShelf(std::move(request), std::move(finish));
    } else {
        resolveIntegrationWithStash(std::move(request), std::move(finish));
    }
}

void GitFeatureModel::cancelIntegrationConflict(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.pendingIntegrationConflict.reset();
    }
    emitState(std::move(handler));
}

void GitFeatureModel::resolveIntegrationWithStash(GitIntegrationConflictRequest request,
                                                  StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    const std::string stashMessage =
        std::string("Lithe auto-stash before ") + integrationOperationId(request.operation);
    GitWriteRequestDto stashRequest;
    stashRequest.operation = "stashPush";
    stashRequest.message = stashMessage;
    stashRequest.includeUntracked = true;
    runWrite(std::move(stashRequest),
        [this, request = std::move(request), stashMessage,
         handler = std::move(handler)](GitFeatureState state) mutable {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
            }
            if (state.error) {
                emitState(std::move(handler));
                return;
            }
            runIntegration(request.reference, request.displayName, request.operation,
                [this, request, stashMessage,
                 handler = std::move(handler)](GitFeatureState) mutable {
                    refreshWorkflow([this, request, stashMessage,
                                    handler = std::move(handler)](GitFeatureState) mutable {
                        std::optional<std::string> stashRef;
                        bool hasConflicts = false;
                        {
                            std::lock_guard lock(mutex_);
                            hasConflicts = state_.operationState &&
                                           state_.operationState->hasConflicts();
                            if (state_.stashes) {
                                for (const auto& stash : state_.stashes->stashes) {
                                    if (stash.message.find(stashMessage) != std::string::npos) {
                                        stashRef = stash.reference;
                                        break;
                                    }
                                }
                            }
                        }
                        const auto title =
                            std::string(integrationOperationTitle(request.operation));
                        std::string titleLower = title;
                        std::transform(titleLower.begin(), titleLower.end(), titleLower.begin(),
                                       [](unsigned char ch) {
                                           return static_cast<char>(std::tolower(ch));
                                       });
                        if (hasConflicts) {
                            {
                                std::lock_guard lock(mutex_);
                                if (stashRef) {
                                    state_.deferredSavedChanges = GitDeferredSavedChanges{
                                        stashRef, std::nullopt, titleLower};
                                }
                                state_.notifyMessage =
                                    "Your changes stay stashed until the " + titleLower +
                                    " is finished";
                            }
                            emitState(std::move(handler));
                            return;
                        }
                        if (!stashRef) {
                            setNotify("Could not find the stashed changes to restore");
                            emitState(std::move(handler));
                            return;
                        }
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = true;
                        }
                        GitWriteRequestDto pop;
                        pop.operation = "stashPop";
                        pop.reference = *stashRef;
                        runWrite(std::move(pop),
                            [this, titleLower,
                             handler = std::move(handler)](GitFeatureState state) {
                                {
                                    std::lock_guard lock(mutex_);
                                    state_.isPerformingBranchOperation = false;
                                }
                                if (state.pendingStashRestoreConflict) {
                                    // already presented with operation title from applyWrite;
                                    // overwrite title if needed
                                    std::lock_guard lock(mutex_);
                                    if (state_.pendingStashRestoreConflict) {
                                        state_.pendingStashRestoreConflict->operationTitle =
                                            titleLower;
                                    }
                                } else if (state.error) {
                                    setNotify("Restoring your changes failed: " +
                                              (state.error->message.empty()
                                                   ? std::string("Git operation failed")
                                                   : state.error->message));
                                }
                                emitState(std::move(handler));
                            });
                    }, true);
                });
        });
}

void GitFeatureModel::resolveIntegrationWithShelf(GitIntegrationConflictRequest request,
                                                  StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    const std::string shelfMessage =
        std::string("Lithe shelf before ") + integrationOperationId(request.operation);
    captureAndCleanShelf(shelfMessage,
        [this, request = std::move(request),
         handler = std::move(handler)](std::optional<GitShelfEntry> shelf,
                                       std::optional<std::string> error) mutable {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
            }
            if (!shelf) {
                if (error) setNotify(*error);
                emitState(std::move(handler));
                return;
            }
            const auto shelfId = shelf->id;
            runIntegration(request.reference, request.displayName, request.operation,
                [this, request, shelf = std::move(*shelf), shelfId,
                 handler = std::move(handler)](GitFeatureState) mutable {
                    refreshWorkflow([this, request, shelf = std::move(shelf), shelfId,
                                    handler = std::move(handler)](GitFeatureState) mutable {
                        bool hasConflicts = false;
                        {
                            std::lock_guard lock(mutex_);
                            hasConflicts = state_.operationState &&
                                           state_.operationState->hasConflicts();
                        }
                        const auto title =
                            std::string(integrationOperationTitle(request.operation));
                        std::string titleLower = title;
                        std::transform(titleLower.begin(), titleLower.end(), titleLower.begin(),
                                       [](unsigned char ch) {
                                           return static_cast<char>(std::tolower(ch));
                                       });
                        if (hasConflicts) {
                            {
                                std::lock_guard lock(mutex_);
                                state_.deferredSavedChanges = GitDeferredSavedChanges{
                                    std::nullopt, shelfId, titleLower};
                                state_.notifyMessage =
                                    "Your shelved changes stay saved until the " +
                                    titleLower + " is finished";
                            }
                            emitState(std::move(handler));
                            return;
                        }
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingShelfOperation = true;
                        }
                        restoreShelf(std::move(shelf),
                            [this, handler = std::move(handler)](bool restored) {
                                {
                                    std::lock_guard lock(mutex_);
                                    state_.isPerformingShelfOperation = false;
                                    if (restored) {
                                        state_.notifyMessage = "Restored your shelved changes";
                                    }
                                }
                                emitState(std::move(handler));
                            });
                    }, true);
                });
        });
}

void GitFeatureModel::fetch(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    GitWriteRequestDto request;
    request.operation = "fetch";
    runWrite(std::move(request),
        [this, handler = std::move(handler)](GitFeatureState state) {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
                if (!state.error) state_.notifyMessage = "Fetched Git remotes";
            }
            emitState(std::move(handler));
        });
}

void GitFeatureModel::push(std::string reference, std::string shortName, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    const auto name = shortName.empty() ? reference : shortName;
    GitWriteRequestDto request;
    request.operation = "push";
    request.reference = std::move(reference);
    runWrite(std::move(request),
        [this, name, handler = std::move(handler)](GitFeatureState state) {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
                if (!state.error) state_.notifyMessage = "Pushed " + name;
            }
            emitState(std::move(handler));
        });
}

void GitFeatureModel::pull(StateHandler handler) {
    auto dirty = dirtyDocumentPaths();
    collectRepoBlocks(
        [this, dirty = std::move(dirty),
         handler = std::move(handler)](bool stale,
                                       std::vector<std::string> unmerged,
                                       std::vector<std::string> markers,
                                       std::optional<CoreError> error) mutable {
            if (stale) {
                emitState(std::move(handler));
                return;
            }
            if (error) {
                {
                    std::lock_guard lock(mutex_);
                    state_.error = std::move(*error);
                }
                emitState(std::move(handler));
                return;
            }
            if (!dirty.empty()) {
                setNotify("Save open documents before pulling");
                emitState(std::move(handler));
                return;
            }
            if (!unmerged.empty() || !markers.empty()) {
                auto blocked = mergeUniquePaths(std::move(unmerged), markers);
                setNotify("Resolve conflicts before pull: " + joinPaths(blocked));
                emitState(std::move(handler));
                return;
            }
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = true;
                state_.pendingPullStrategy.reset();
            }
            coordinator_.gitPullPreflight(
                [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
                    if (result.stale) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    if (!result.envelope || !result.envelope->ok) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            if (const auto coreError = result.coreError()) {
                                state_.error = *coreError;
                            }
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    auto dto = decodeGitPullPreflight(*result.envelope);
                    if (!dto) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            state_.error = CoreError{CoreErrorCode::ParseFailed,
                                                     "Invalid Git pull preflight response",
                                                     std::nullopt};
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    if (!dto->upstream) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            state_.notifyMessage = "Current branch tracks no remote branch";
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    if (dto->ahead == 0 && dto->behind == 0) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            state_.notifyMessage = "Already up to date";
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    if (dto->diverged) {
                        {
                            std::lock_guard lock(mutex_);
                            state_.isPerformingBranchOperation = false;
                            state_.pendingPullStrategy = GitPullStrategyRequest{
                                *dto->upstream, dto->ahead, dto->behind, dto->hasLocalChanges};
                        }
                        emitState(std::move(handler));
                        return;
                    }
                    runPull("ffOnly", "Updated current branch", std::move(handler));
                });
        });
}

void GitFeatureModel::resolvePullStrategy(GitPullStrategy strategy, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.pendingPullStrategy.reset();
    }
    auto dirty = dirtyDocumentPaths();
    collectRepoBlocks(
        [this, strategy, dirty = std::move(dirty),
         handler = std::move(handler)](bool stale,
                                       std::vector<std::string> unmerged,
                                       std::vector<std::string> markers,
                                       std::optional<CoreError> error) mutable {
            if (stale) {
                emitState(std::move(handler));
                return;
            }
            if (error) {
                {
                    std::lock_guard lock(mutex_);
                    state_.error = std::move(*error);
                }
                emitState(std::move(handler));
                return;
            }
            if (!dirty.empty()) {
                setNotify("Save open documents before pulling");
                emitState(std::move(handler));
                return;
            }
            if (!unmerged.empty() || !markers.empty()) {
                auto blocked = mergeUniquePaths(std::move(unmerged), markers);
                setNotify("Resolve conflicts before pull: " + joinPaths(blocked));
                emitState(std::move(handler));
                return;
            }
            const char* success =
                strategy == GitPullStrategy::Rebase ? "Rebased onto upstream" : "Merged upstream";
            runPull(pullModeId(strategy), success, std::move(handler));
        });
}

void GitFeatureModel::cancelPullStrategy(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.pendingPullStrategy.reset();
    }
    emitState(std::move(handler));
}

void GitFeatureModel::runPull(std::optional<std::string> mode,
                              std::string successMessage,
                              StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingBranchOperation = true;
    }
    GitWriteRequestDto request;
    request.operation = "pull";
    request.mode = std::move(mode);
    runWrite(std::move(request),
        [this, successMessage = std::move(successMessage),
         handler = std::move(handler)](GitFeatureState state) {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingBranchOperation = false;
            }
            reportBranchOperation(!state.error, std::move(successMessage), std::move(handler));
        });
}

void GitFeatureModel::commitAndPush(std::string message, bool amend, StateHandler handler) {
    while (!message.empty() &&
           (message.front() == ' ' || message.front() == '\t' ||
            message.front() == '\n' || message.front() == '\r')) {
        message.erase(message.begin());
    }
    while (!message.empty() &&
           (message.back() == ' ' || message.back() == '\t' ||
            message.back() == '\n' || message.back() == '\r')) {
        message.pop_back();
    }
    if (message.empty()) {
        setNotify("Enter a commit message");
        emitState(std::move(handler));
        return;
    }
    gateCommitWrite(std::move(message), amend, true, std::move(handler));
}

void GitFeatureModel::performCommitAndPush(std::string message,
                                           bool amend,
                                           StateHandler handler) {
    std::optional<std::string> branch;
    {
        std::lock_guard lock(mutex_);
        if (state_.status) branch = state_.status->branch;
    }

    GitWriteRequestDto commitRequest;
    commitRequest.operation = "commit";
    commitRequest.message = std::move(message);
    commitRequest.amend = amend;
    // Outer begin nests with runWrite's begin/end so watcher freeze stays up for
    // commit+push and refresh runs once on the final endOperation.
    beginOperation();
    runWrite(std::move(commitRequest),
        [this, branch = std::move(branch),
         handler = std::move(handler)](GitFeatureState state) mutable {
            if (state.error) {
                endOperation(std::move(handler), true);
                return;
            }
            if (!branch || branch->empty()) {
                setNotify("Committed changes, but detached HEAD cannot be pushed");
                endOperation(std::move(handler), true);
                return;
            }
            GitWriteRequestDto pushRequest;
            pushRequest.operation = "push";
            pushRequest.reference = *branch;
            const auto name = *branch;
            runWrite(std::move(pushRequest),
                [this, name, handler = std::move(handler)](GitFeatureState state) {
                    if (!state.error) {
                        setNotify("Committed and pushed " + name);
                    } else {
                        setNotify("Committed changes, but push failed: " +
                                  (state.error->details.value_or(state.error->message)));
                    }
                    endOperation(std::move(handler), true);
                });
        });
}

void GitFeatureModel::discardConflictPath(std::string path, StateHandler handler) {
    discard(std::vector<std::string>{std::move(path)},
        [this, handler = std::move(handler)](GitFeatureState state) mutable {
            if (state.error) {
                emitState(std::move(handler));
                return;
            }
            retryPendingPreflight(std::move(handler));
        });
}

void GitFeatureModel::retryPendingPreflight(StateHandler handler) {
    std::optional<GitCheckoutConflictRequest> checkout;
    std::optional<GitIntegrationConflictRequest> integration;
    {
        std::lock_guard lock(mutex_);
        checkout = state_.pendingCheckoutConflict;
        integration = state_.pendingIntegrationConflict;
    }
    if (checkout) {
        checkoutReference(std::move(checkout->reference),
                          std::move(checkout->referenceKind),
                          std::move(checkout->shortName),
                          std::move(handler));
        return;
    }
    if (integration) {
        startIntegration(std::move(integration->reference),
                         std::move(integration->displayName),
                         integration->operation,
                         std::move(handler));
        return;
    }
    emitState(std::move(handler));
}

void GitFeatureModel::continueOperation(StateHandler handler) {
    resolveGitOperation("operationContinue", std::move(handler));
}

void GitFeatureModel::abortOperation(StateHandler handler) {
    resolveGitOperation("operationAbort", std::move(handler));
}

void GitFeatureModel::skipOperation(StateHandler handler) {
    resolveGitOperation("operationSkip", std::move(handler));
}

void GitFeatureModel::resolveGitOperation(std::string operation, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        if (state_.isResolvingGitOperation) {
            emitState(std::move(handler));
            return;
        }
        state_.isResolvingGitOperation = true;
    }
    GitWriteRequestDto request;
    request.operation = std::move(operation);
    runWrite(std::move(request),
        [this, handler = std::move(handler)](GitFeatureState writeState) mutable {
            bool cleared = false;
            {
                std::lock_guard lock(mutex_);
                state_.isResolvingGitOperation = false;
                cleared = !state_.operationState.has_value() ||
                          !state_.operationState->isActive();
                if (writeState.error) {
                    // keep write error / notify from command
                } else if (cleared) {
                    state_.notifyMessage = "Git operation finished";
                }
            }
            if (cleared) {
                restoreDeferredSavedChanges(std::move(handler));
            } else {
                emitState(std::move(handler));
            }
        });
}

void GitFeatureModel::restoreDeferredSavedChanges(StateHandler handler) {
    GitDeferredSavedChanges deferred;
    {
        std::lock_guard lock(mutex_);
        if (!state_.deferredSavedChanges) {
            emitState(std::move(handler));
            return;
        }
        deferred = *state_.deferredSavedChanges;
        state_.deferredSavedChanges.reset();
    }

    if (deferred.stashReference) {
        const auto stashRef = *deferred.stashReference;
        bool found = false;
        {
            std::lock_guard lock(mutex_);
            if (state_.stashes) {
                for (const auto& stash : state_.stashes->stashes) {
                    if (stash.reference == stashRef) {
                        found = true;
                        break;
                    }
                }
            }
        }
        if (!found) {
            setNotify("Could not find the saved local changes after the Git operation");
            emitState(std::move(handler));
            return;
        }
        {
            std::lock_guard lock(mutex_);
            state_.isPerformingBranchOperation = true;
        }
        GitWriteRequestDto pop;
        pop.operation = "stashPop";
        pop.reference = stashRef;
        runWrite(std::move(pop),
            [this, title = deferred.operationTitle,
             handler = std::move(handler)](GitFeatureState state) {
                {
                    std::lock_guard lock(mutex_);
                    state_.isPerformingBranchOperation = false;
                    if (state_.pendingStashRestoreConflict) {
                        state_.pendingStashRestoreConflict->operationTitle = title;
                    } else if (state.error) {
                        state_.notifyMessage =
                            "Restoring your changes failed: " + state.error->message;
                    } else {
                        state_.notifyMessage = "Restored your local changes";
                    }
                }
                emitState(std::move(handler));
            });
        return;
    }

    if (!deferred.shelfId) {
        emitState(std::move(handler));
        return;
    }
    std::optional<GitShelfEntry> shelf;
    {
        std::lock_guard lock(mutex_);
        for (const auto& entry : state_.shelves) {
            if (entry.id == *deferred.shelfId) {
                shelf = entry;
                break;
            }
        }
    }
    if (!shelf) {
        setNotify("Could not find the saved shelf after the Git operation");
        emitState(std::move(handler));
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingShelfOperation = true;
    }
    restoreShelf(std::move(*shelf), [this, handler = std::move(handler)](bool restored) {
        {
            std::lock_guard lock(mutex_);
            state_.isPerformingShelfOperation = false;
            if (restored) state_.notifyMessage = "Restored your shelved changes";
        }
        emitState(std::move(handler));
    });
}

void GitFeatureModel::refreshShelves(StateHandler handler) {
    std::optional<std::string> root;
    ShelveService* service = nullptr;
    {
        std::lock_guard lock(mutex_);
        service = shelveService_;
        root = repositoryRootLocked();
    }
    if (service == nullptr || !root) {
        {
            std::lock_guard lock(mutex_);
            state_.shelves.clear();
        }
        emitState(std::move(handler));
        return;
    }
    auto shelves = service->entries(*root);
    {
        std::lock_guard lock(mutex_);
        state_.shelves = std::move(shelves);
    }
    emitState(std::move(handler));
}

void GitFeatureModel::shelveWorkingTree(std::string message, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        if (shelveService_ == nullptr) {
            state_.notifyMessage = "Shelve storage is unavailable";
            emitState(std::move(handler));
            return;
        }
        state_.isPerformingShelfOperation = true;
    }
    beginOperation();
    captureAndCleanShelf(std::move(message),
        [this, handler = std::move(handler)](std::optional<GitShelfEntry> shelf,
                                             std::optional<std::string> error) {
            {
                std::lock_guard lock(mutex_);
                state_.isPerformingShelfOperation = false;
                if (shelf) {
                    state_.notifyMessage =
                        "Shelved " + std::to_string(shelf->paths.size()) + " file(s)";
                } else if (error) {
                    state_.notifyMessage = *error;
                }
            }
            endOperation(std::move(handler), true);
        });
}

void GitFeatureModel::applyShelf(GitShelfEntry shelf, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingShelfOperation = true;
    }
    beginOperation();
    restoreShelf(std::move(shelf), [this, handler = std::move(handler)](bool restored) {
        {
            std::lock_guard lock(mutex_);
            state_.isPerformingShelfOperation = false;
            if (restored) state_.notifyMessage = "Restored shelf";
        }
        endOperation(std::move(handler), true);
    });
}

void GitFeatureModel::dropShelf(GitShelfEntry shelf, StateHandler handler) {
    std::optional<std::string> root;
    ShelveService* service = nullptr;
    {
        std::lock_guard lock(mutex_);
        service = shelveService_;
        root = repositoryRootLocked();
        state_.isPerformingShelfOperation = true;
    }
    if (service == nullptr || !root) {
        {
            std::lock_guard lock(mutex_);
            state_.isPerformingShelfOperation = false;
            state_.notifyMessage = "Shelve storage is unavailable";
        }
        emitState(std::move(handler));
        return;
    }
    beginOperation();
    const bool deleted = service->remove(*root, shelf);
    {
        std::lock_guard lock(mutex_);
        state_.isPerformingShelfOperation = false;
        state_.notifyMessage = deleted ? "Dropped shelf" : "Could not drop shelf";
    }
    refreshShelves({});
    endOperation(std::move(handler), true);
}

void GitFeatureModel::captureAndCleanShelf(std::string message, ShelfCaptureHandler handler) {
    ShelveService* service = nullptr;
    std::vector<GitChangeDto> changes;
    std::optional<std::string> root;
    {
        std::lock_guard lock(mutex_);
        service = shelveService_;
        root = repositoryRootLocked();
        if (state_.status) changes = state_.status->changes;
    }
    if (service == nullptr) {
        if (handler) handler(std::nullopt, "Shelve storage is unavailable");
        return;
    }
    if (!root) {
        if (handler) handler(std::nullopt, "No Git repository is open");
        return;
    }
    if (changes.empty()) {
        if (handler) handler(std::nullopt, "There are no changes to shelve");
        return;
    }
    if (std::any_of(changes.begin(), changes.end(), isConflictedChange)) {
        if (handler) handler(std::nullopt, "Resolve existing conflicts before shelving changes");
        return;
    }

    struct CaptureState {
        std::string message;
        std::string root;
        ShelveService* service = nullptr;
        std::vector<GitChangeDto> changes;
        std::size_t index = 0;
        std::vector<std::string> stagedPatches;
        std::vector<std::string> workingPatches;
        ShelfCaptureHandler handler;
        std::function<void()> next;
        std::function<void()> discardNext;
        std::size_t discardIndex = 0;
    };
    auto capture = std::make_shared<CaptureState>();
    capture->message = std::move(message);
    capture->root = *root;
    capture->service = service;
    capture->changes = std::move(changes);
    capture->handler = std::move(handler);

    capture->next = [this, capture] {
        if (capture->index >= capture->changes.size()) {
            std::string stagedPatch;
            std::string workingPatch;
            for (std::size_t i = 0; i < capture->stagedPatches.size(); ++i) {
                if (i > 0) stagedPatch.push_back('\n');
                stagedPatch += capture->stagedPatches[i];
            }
            for (std::size_t i = 0; i < capture->workingPatches.size(); ++i) {
                if (i > 0) workingPatch.push_back('\n');
                workingPatch += capture->workingPatches[i];
            }
            if (isBlank(stagedPatch) && isBlank(workingPatch)) {
                auto completed = std::move(capture->handler);
                capture->next = {};
                if (completed) {
                    completed(std::nullopt, "Could not create a patch for these changes");
                }
                return;
            }
            std::set<std::string> pathSet;
            for (const auto& change : capture->changes) {
                for (const auto& path : pathspecsFor(change)) pathSet.insert(path);
            }
            std::vector<std::string> paths(pathSet.begin(), pathSet.end());
            auto entry = capture->service->save(capture->root, capture->message, std::move(paths),
                                                std::move(stagedPatch), std::move(workingPatch));
            if (!entry) {
                auto completed = std::move(capture->handler);
                capture->next = {};
                if (completed) completed(std::nullopt, "Could not save the shelf");
                return;
            }
            auto held = std::make_shared<GitShelfEntry>(std::move(*entry));
            capture->discardIndex = 0;
            capture->discardNext = [this, capture, held] {
                if (capture->discardIndex >= capture->changes.size()) {
                    auto completed = std::move(capture->handler);
                    capture->next = {};
                    capture->discardNext = {};
                    if (completed) completed(*held, std::nullopt);
                    return;
                }
                const auto& change = capture->changes[capture->discardIndex];
                GitWriteRequestDto request;
                request.operation = "discardAll";
                request.paths = pathspecsFor(change);
                const auto path = change.path;
                runWrite(std::move(request), [capture, path, held](GitFeatureState state) {
                    if (state.error) {
                        auto completed = std::move(capture->handler);
                        capture->next = {};
                        capture->discardNext = {};
                        if (completed) {
                            completed(std::nullopt,
                                      "Shelf saved, but could not clear " + path + ": " +
                                          state.error->message);
                        }
                        return;
                    }
                    ++capture->discardIndex;
                    capture->discardNext();
                });
            };
            capture->discardNext();
            return;
        }

        const auto& change = capture->changes[capture->index];
        auto afterStaged = [this, capture](std::string staged) {
            if (!isBlank(staged)) capture->stagedPatches.push_back(std::move(staged));
            const auto& change = capture->changes[capture->index];
            if (!(change.worktree || change.untracked)) {
                ++capture->index;
                capture->next();
                return;
            }
            coordinator_.gitDiff(pathspecsFor(change), false, change.untracked,
                [capture](WorkspaceOperationResult result) {
                    std::string patch;
                    if (!result.stale && result.envelope && result.envelope->ok) {
                        if (auto diff = decodeGitDiff(*result.envelope)) {
                            patch = std::move(diff->patch);
                        }
                    }
                    if (!isBlank(patch)) capture->workingPatches.push_back(std::move(patch));
                    ++capture->index;
                    capture->next();
                });
        };

        if (change.staged) {
            coordinator_.gitDiff(pathspecsFor(change), true, false,
                [afterStaged = std::move(afterStaged)](WorkspaceOperationResult result) mutable {
                    std::string patch;
                    if (!result.stale && result.envelope && result.envelope->ok) {
                        if (auto diff = decodeGitDiff(*result.envelope)) {
                            patch = std::move(diff->patch);
                        }
                    }
                    afterStaged(std::move(patch));
                });
        } else {
            afterStaged({});
        }
    };
    capture->next();
}

void GitFeatureModel::restoreShelf(GitShelfEntry shelf, std::function<void(bool)> handler) {
    ShelveService* service = nullptr;
    std::optional<std::string> root;
    {
        std::lock_guard lock(mutex_);
        service = shelveService_;
        root = repositoryRootLocked();
    }
    if (service == nullptr || !root) {
        if (handler) handler(false);
        return;
    }

    auto continueWorking = [this, shelf, service, root = *root,
                            handler = std::move(handler)]() mutable {
        if (isBlank(shelf.workingPatch)) {
            const bool removed = service->remove(root, shelf);
            if (!removed) setNotify("Shelf restored, but it could not be removed");
            refreshShelves({});
            if (handler) handler(true);
            return;
        }
        applyPatchChecked(shelf.workingPatch, "worktree", "worktreeCheck",
            [this, shelf = std::move(shelf), service, root = std::move(root),
             handler = std::move(handler)](bool ok, std::string message) mutable {
                if (!ok) {
                    setNotify("Shelf partially restored; it was kept for retry: " + message);
                    refreshShelves({});
                    if (handler) handler(false);
                    return;
                }
                const bool removed = service->remove(root, shelf);
                if (!removed) setNotify("Shelf restored, but it could not be removed");
                refreshShelves({});
                if (handler) handler(true);
            });
    };

    if (isBlank(shelf.stagedPatch)) {
        continueWorking();
        return;
    }
    applyPatchChecked(shelf.stagedPatch, "restoreIndex", "restoreIndexCheck",
        [this, continueWorking = std::move(continueWorking),
         handler](bool ok, std::string message) mutable {
            if (!ok) {
                setNotify("Could not restore shelf: " + message);
                if (handler) handler(false);
                return;
            }
            continueWorking();
        });
}

void GitFeatureModel::applyPatchChecked(std::string patch,
                                        std::string mode,
                                        std::string checkMode,
                                        std::function<void(bool, std::string)> handler) {
    beginOperation();
    const auto requestSerial = ++applyRequestSerial_;
    {
        std::lock_guard lock(mutex_);
        state_.isApplying = true;
    }
    coordinator_.gitApply(patch, std::move(mode),
        [this, patch = std::move(patch), checkMode = std::move(checkMode),
         handler = std::move(handler), requestSerial](WorkspaceOperationResult result) mutable {
            applyPatch(std::move(result), {}, requestSerial);
            bool ok = false;
            std::string message;
            {
                std::lock_guard lock(mutex_);
                if (!state_.error && state_.command && state_.command->exitCode == 0) {
                    ok = true;
                } else if (state_.command) {
                    message = failureMessage(*state_.command);
                } else if (state_.error) {
                    message = state_.error->message;
                } else {
                    message = "Git apply failed";
                }
            }
            if (ok) {
                endOperation([handler = std::move(handler)](GitFeatureState) {
                    if (handler) handler(true, {});
                }, false);
                return;
            }
            const auto checkSerial = ++applyRequestSerial_;
            coordinator_.gitApply(std::move(patch), std::move(checkMode),
                [this, message = std::move(message),
                 handler = std::move(handler),
                 checkSerial](WorkspaceOperationResult checkResult) mutable {
                    bool alreadyApplied = false;
                    if (!checkResult.stale && checkResult.envelope && checkResult.envelope->ok) {
                        if (auto command = decodeGitCommand(*checkResult.envelope)) {
                            alreadyApplied = command->exitCode == 0;
                        }
                    }
                    {
                        std::lock_guard lock(mutex_);
                        if (checkSerial == applyRequestSerial_) {
                            state_.isApplying = false;
                        }
                    }
                    endOperation(
                        [alreadyApplied, message = std::move(message),
                         handler = std::move(handler)](GitFeatureState) mutable {
                            if (handler) handler(alreadyApplied, std::move(message));
                        },
                        false);
                });
        });
}

void GitFeatureModel::dismissStashRestoreNotice(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.stashRestoreNoticeVisible = false;
    }
    emitState(std::move(handler));
}

void GitFeatureModel::showStashRestoreNotice(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        if (state_.pendingStashRestoreConflict) {
            state_.stashRestoreNoticeVisible = true;
        }
    }
    emitState(std::move(handler));
}

void GitFeatureModel::setConflictFilterPaths(std::vector<std::string> paths,
                                             StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.conflictFilterPaths = std::move(paths);
    }
    emitState(std::move(handler));
}

void GitFeatureModel::clearConflictFilterPaths(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.conflictFilterPaths.clear();
    }
    emitState(std::move(handler));
}

GitFeatureState GitFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void GitFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
    operationDepth_ = 0;
    refreshStashesOnEnd_ = false;
    ++applyRequestSerial_;
}

void GitFeatureModel::applyStatus(WorkspaceOperationResult result, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingStatus = false;
        if (!result.stale) {
            if (result.envelope && result.envelope->ok) {
                if (auto status = decodeGitStatus(*result.envelope)) {
                    state_.status = std::move(*status);
                    if (!state_.conflictFilterPaths.empty() && state_.status) {
                        std::set<std::string> present;
                        for (const auto& change : state_.status->changes) {
                            present.insert(change.path);
                        }
                        state_.conflictFilterPaths.erase(
                            std::remove_if(state_.conflictFilterPaths.begin(),
                                           state_.conflictFilterPaths.end(),
                                           [&](const std::string& path) {
                                               return !present.contains(path);
                                           }),
                            state_.conflictFilterPaths.end());
                    }
                    state_.error.reset();
                } else {
                    state_.error = CoreError{
                        CoreErrorCode::ParseFailed, "Invalid Git status response",
                        std::nullopt};
                }
            } else if (const auto error = result.coreError()) {
                state_.error = *error;
            } else {
                state_.error =
                    CoreError{CoreErrorCode::Unknown, "Git status failed", std::nullopt};
            }
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyDiff(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingDiff = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingDiff = false;
        if (result.envelope && result.envelope->ok) {
            if (auto diff = decodeGitDiff(*result.envelope)) {
                state_.diff = std::move(*diff);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git diff response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git diff failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyHistory(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingHistory = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingHistory = false;
        if (result.envelope && result.envelope->ok) {
            if (auto history = decodeGitHistory(*result.envelope)) {
                state_.history = std::move(*history);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git history response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git history failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyCommit(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommit = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommit = false;
        if (result.envelope && result.envelope->ok) {
            if (auto commit = decodeGitCommit(*result.envelope)) {
                state_.commit = std::move(*commit);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git commit response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git commit failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyCommitFiles(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommitFiles = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommitFiles = false;
        if (result.envelope && result.envelope->ok) {
            if (auto files = decodeGitCommitFiles(*result.envelope)) {
                state_.commitFiles = std::move(*files);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git commit files response",
                    std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git commit files failed",
                                    std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyComparison(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingComparison = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingComparison = false;
        if (result.envelope && result.envelope->ok) {
            if (auto comparison = decodeGitComparison(*result.envelope)) {
                state_.comparison = std::move(*comparison);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git comparison response",
                    std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git comparison failed",
                                    std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyStashes(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingStashes = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingStashes = false;
        if (result.envelope && result.envelope->ok) {
            if (auto stashes = decodeGitStashesResponse(*result.envelope)) {
                state_.stashes = std::move(*stashes);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git stashes response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git stashes failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyBlame(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingBlame = false;
    } else {
        std::lock_guard lock(mutex_);
        state_.isLoadingBlame = false;
        if (result.envelope && result.envelope->ok) {
            if (auto blame = decodeGitBlameResponse(*result.envelope)) {
                state_.blame = std::move(*blame);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git blame response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git blame failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyCheckoutPreflight(WorkspaceOperationResult result,
                                             StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingCheckoutPreflight = false;
        if (result.envelope && result.envelope->ok) {
            if (auto preflight = decodeGitCheckoutPreflight(*result.envelope)) {
                state_.checkoutPreflight = std::move(*preflight);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed,
                    "Invalid Git checkout preflight response",
                    std::nullopt,
                };
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Git checkout preflight failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyPullPreflight(WorkspaceOperationResult result,
                                         StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingPullPreflight = false;
        if (result.envelope && result.envelope->ok) {
            if (auto preflight = decodeGitPullPreflight(*result.envelope)) {
                state_.pullPreflight = std::move(*preflight);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed,
                    "Invalid Git pull preflight response",
                    std::nullopt,
                };
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Git pull preflight failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyIntegrationPreflight(WorkspaceOperationResult result,
                                                StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingIntegrationPreflight = false;
        if (result.envelope && result.envelope->ok) {
            if (auto preflight = decodeGitIntegrationPreflight(*result.envelope)) {
                state_.integrationPreflight = std::move(*preflight);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed,
                    "Invalid Git integration preflight response",
                    std::nullopt,
                };
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Git integration preflight failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyConflictMarkers(WorkspaceOperationResult result,
                                           StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingConflictMarkers = false;
        if (result.envelope && result.envelope->ok) {
            if (auto markers = decodeGitConflictMarkers(*result.envelope)) {
                state_.conflictMarkers = std::move(*markers);
                rebuildConflictFilterPaths();
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed,
                    "Invalid Git conflict marker response",
                    std::nullopt,
                };
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Git conflict marker check failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyOperationState(WorkspaceOperationResult result,
                                          StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingOperationState = false;
        if (result.envelope && result.envelope->ok) {
            if (auto operationState = decodeGitOperationState(*result.envelope)) {
                if (operationState->kind.empty()) {
                    state_.operationState.reset();
                } else {
                    state_.operationState = std::move(*operationState);
                }
                rebuildConflictFilterPaths();
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed,
                    "Invalid Git operation state response",
                    std::nullopt,
                };
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Git operation state failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyWrite(WorkspaceOperationResult result, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isWriting = false;
        if (!result.stale) {
            if (result.envelope && result.envelope->ok) {
                if (auto command = decodeGitCommand(*result.envelope)) {
                    state_.command = std::move(*command);
                    if (state_.command->stashRestore) {
                        presentStashRestoreConflictLocked(
                            *state_.command->stashRestore,
                            "stash restore",
                            state_.command->output.empty()
                                ? std::nullopt
                                : std::optional<std::string>(state_.command->output));
                    } else if (state_.command->exitCode == 0) {
                        state_.error.reset();
                    } else {
                        state_.error = CoreError{
                            CoreErrorCode::ProcessFailed,
                            "Git command failed",
                            state_.command->output.empty()
                                ? std::nullopt
                                : std::optional<std::string>(state_.command->output),
                        };
                    }
                } else {
                    state_.error = CoreError{
                        CoreErrorCode::ParseFailed, "Invalid Git write response",
                        std::nullopt};
                }
            } else if (const auto error = result.coreError()) {
                state_.error = *error;
            } else {
                state_.error =
                    CoreError{CoreErrorCode::Unknown, "Git write failed", std::nullopt};
            }
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyPatch(WorkspaceOperationResult result,
                                 StateHandler handler,
                                 std::uint64_t requestSerial) {
    if (result.stale) {
        bool current = false;
        {
            std::lock_guard lock(mutex_);
            current = requestSerial == applyRequestSerial_;
            if (!current) return;
            state_.isApplying = false;
            state_.error = CoreError{
                CoreErrorCode::Cancelled, "Git apply request became stale", std::nullopt};
        }
        if (handler) handler(state());
        return;
    }
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isApplying = false;
        if (result.envelope && result.envelope->ok) {
            if (auto command = decodeGitCommand(*result.envelope)) {
                state_.command = *command;
                if (command->exitCode == 0) {
                    state_.error.reset();
                } else {
                    state_.error = CoreError{
                        CoreErrorCode::ProcessFailed,
                        "Git apply failed",
                        command->output.empty()
                            ? std::nullopt
                            : std::optional<std::string>(command->output),
                    };
                }
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git apply response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::ParseFailed, "Invalid Git apply response", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::rebuildConflictFilterPaths() {
    state_.conflictFilterPaths.clear();
    if (state_.operationState) {
        state_.conflictFilterPaths.insert(
            state_.conflictFilterPaths.end(),
            state_.operationState->conflictedPaths.begin(),
            state_.operationState->conflictedPaths.end());
    }
    if (state_.conflictMarkers) {
        state_.conflictFilterPaths.insert(
            state_.conflictFilterPaths.end(),
            state_.conflictMarkers->paths.begin(),
            state_.conflictMarkers->paths.end());
    }
    if (state_.stashRestoreConflict) {
        state_.conflictFilterPaths.insert(
            state_.conflictFilterPaths.end(),
            state_.stashRestoreConflict->conflictedPaths.begin(),
            state_.stashRestoreConflict->conflictedPaths.end());
    }
    std::sort(state_.conflictFilterPaths.begin(), state_.conflictFilterPaths.end());
    state_.conflictFilterPaths.erase(
        std::unique(state_.conflictFilterPaths.begin(), state_.conflictFilterPaths.end()),
        state_.conflictFilterPaths.end());
}

} // namespace lithe::windows::app
