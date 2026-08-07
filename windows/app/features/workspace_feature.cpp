#include "workspace_feature.h"

namespace lithe::windows::app {

WorkspaceFeatureModel::WorkspaceFeatureModel(WorkbenchCoordinator& coordinator)
    : coordinator_(coordinator) {}

void WorkspaceFeatureModel::open(std::filesystem::path root, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.root = root;
        state_.snapshot.reset();
        state_.error.reset();
        state_.isLoading = true;
    }
    coordinator_.openWorkspace(std::move(root), [this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        apply(std::move(result), std::move(handler));
    });
}

void WorkspaceFeatureModel::refresh(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.error.reset();
        state_.isLoading = true;
    }
    coordinator_.refreshWorkspace([this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        apply(std::move(result), std::move(handler));
    });
}

void WorkspaceFeatureModel::close() {
    resetForWorkspace();
}

void WorkspaceFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
}

WorkspaceFeatureState WorkspaceFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void WorkspaceFeatureModel::apply(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            if (auto snapshot = decodeWorkspaceSnapshot(*result.envelope)) {
                state_.snapshot = std::move(*snapshot);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid workspace snapshot response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Workspace request failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

} // namespace lithe::windows::app
