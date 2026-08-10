#include "git_feature.h"

#include <algorithm>
#include <memory>

namespace lithe::windows::app {

GitFeatureModel::GitFeatureModel(WorkbenchCoordinator& coordinator,
                                 DocumentSafetySnapshotProvider* documents)
    : coordinator_(coordinator), documents_(documents) {}

void GitFeatureModel::refreshStatus(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingStatus = true;
        state_.error.reset();
    }
    coordinator_.gitStatus([this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        applyStatus(std::move(result), std::move(handler));
    });
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
    if (blockUnsafeDocumentMutation(request.operation, handler)) return;
    {
        std::lock_guard lock(mutex_);
        state_.isWriting = true;
        state_.error.reset();
    }
    coordinator_.gitWrite(std::move(request),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyWrite(std::move(result), std::move(handler));
    });
}

bool GitFeatureModel::blockUnsafeDocumentMutation(const std::string& operation,
                                                  StateHandler& handler) {
    if (documents_ == nullptr) return false;
    static const std::vector<std::string> worktreeMutations{
        "discard", "discardAll", "checkout", "checkoutRevision", "pull", "merge",
        "rebase", "cherryPick", "revert", "reset", "stashApply", "stashPop",
        "operationContinue", "operationAbort", "operationSkip"
    };
    if (std::find(worktreeMutations.begin(), worktreeMutations.end(), operation) ==
        worktreeMutations.end()) return false;
    const auto snapshot = documents_->documentSafetySnapshot();
    if (snapshot.dirtyPaths.empty() && !snapshot.isSaving && !snapshot.hasConflicts) return false;
    GitFeatureState state;
    {
        std::lock_guard lock(mutex_);
        state_.documentSafety = snapshot;
        state_.isWriting = false;
        state_.error = CoreError{
            CoreErrorCode::InvalidRequest,
            "Save or close dirty and conflicted documents before this Git operation",
            std::nullopt};
        state = state_;
    }
    if (handler) handler(std::move(state));
    return true;
}

void GitFeatureModel::runCommand(std::vector<std::string> arguments,
                                 std::optional<std::string> input,
                                 StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isWriting = true;
        state_.error.reset();
    }
    coordinator_.gitCommand(GitCommandRequestDto{{}, std::move(arguments), std::move(input)},
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applyWrite(std::move(result), std::move(handler));
    });
}

void GitFeatureModel::stage(std::vector<std::string> paths, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stage";
    request.paths = std::move(paths);
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::unstage(std::vector<std::string> paths, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "unstage";
    request.paths = std::move(paths);
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::discard(std::vector<std::string> paths, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "discard";
    request.paths = std::move(paths);
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::stageAll(StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stageAll";
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::commit(std::string message, bool amend, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "commit";
    request.message = std::move(message);
    request.amend = amend;
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::stash(std::string message,
                            bool includeUntracked,
                            StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashPush";
    request.message = std::move(message);
    request.includeUntracked = includeUntracked;
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::applyStash(std::string reference, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashApply";
    request.reference = std::move(reference);
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::popStash(std::string reference, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashPop";
    request.reference = std::move(reference);
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::dropStash(std::string reference, StateHandler handler) {
    GitWriteRequestDto request;
    request.operation = "stashDrop";
    request.reference = std::move(reference);
    write(std::move(request), std::move(handler));
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
    write(std::move(request), std::move(handler));
}

void GitFeatureModel::apply(std::string patch, std::string mode, StateHandler handler) {
    if ((mode == "discard" || mode == "restoreIndex" || mode == "worktree") &&
        blockUnsafeDocumentMutation("discard", handler)) return;
    const auto requestSerial = ++applyRequestSerial_;
    {
        std::lock_guard lock(mutex_);
        state_.isApplying = true;
        state_.error.reset();
    }
    coordinator_.gitApply(std::move(patch), std::move(mode),
        [this, handler = std::move(handler), requestSerial](WorkspaceOperationResult result) mutable {
        applyPatch(std::move(result), std::move(handler), requestSerial);
    });
}

GitFeatureState GitFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void GitFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
    ++applyRequestSerial_;
}

void GitFeatureModel::applyStatus(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingStatus = false;
        if (result.envelope && result.envelope->ok) {
            if (auto status = decodeGitStatus(*result.envelope)) {
                state_.status = std::move(*status);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git status response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git status failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyDiff(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
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
    if (result.stale) return;
    if (!result.stale) {
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
    if (result.stale) return;
    if (!result.stale) {
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
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingCommitFiles = false;
        if (result.envelope && result.envelope->ok) {
            if (auto files = decodeGitCommitFiles(*result.envelope)) {
                state_.commitFiles = std::move(*files);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git commit files response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git commit files failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyComparison(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingComparison = false;
        if (result.envelope && result.envelope->ok) {
            if (auto comparison = decodeGitComparison(*result.envelope)) {
                state_.comparison = std::move(*comparison);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid Git comparison response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git comparison failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void GitFeatureModel::applyStashes(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
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
    if (result.stale) return;
    if (!result.stale) {
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
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isWriting = false;
        if (result.envelope && result.envelope->ok) {
            if (auto command = decodeGitCommand(*result.envelope)) {
                state_.command = std::move(*command);
                if (state_.command->stashRestore) {
                    state_.stashRestoreConflict = state_.command->stashRestore;
                    rebuildConflictFilterPaths();
                }
                if (state_.command->exitCode == 0) {
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
                    CoreErrorCode::ParseFailed, "Invalid Git write response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Git write failed", std::nullopt};
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
