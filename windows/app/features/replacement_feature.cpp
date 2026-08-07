#include "replacement_feature.h"

#include <utility>

namespace lithe::windows::app {

ReplacementFeatureModel::ReplacementFeatureModel(WorkbenchCoordinator& coordinator)
    : coordinator_(coordinator) {}

void ReplacementFeatureModel::preview(ReplacementPreviewRequestDto request,
                                      StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = true;
        state_.error.reset();
    }
    coordinator_.replacementPreview(std::move(request),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        apply(std::move(result), std::move(handler));
    });
}

void ReplacementFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
}

ReplacementFeatureState ReplacementFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void ReplacementFeatureModel::apply(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            if (auto preview = decodeReplacementPreview(*result.envelope)) {
                state_.preview = std::move(*preview);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid replacement preview response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{
                CoreErrorCode::Unknown, "Replacement preview failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

} // namespace lithe::windows::app
