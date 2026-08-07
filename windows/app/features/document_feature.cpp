#include "document_feature.h"

namespace lithe::windows::app {

DocumentFeatureModel::DocumentFeatureModel(WorkbenchCoordinator& coordinator)
    : coordinator_(coordinator) {}

void DocumentFeatureModel::open(std::string relativePath, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.relativePath = relativePath;
        state_.text.clear();
        state_.isLoading = true;
        state_.isSaving = false;
        state_.isDirty = false;
        state_.error.reset();
    }
    coordinator_.readFile(std::move(relativePath), [this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        applyRead(std::move(result), std::move(handler));
    });
}

void DocumentFeatureModel::setText(std::string text) {
    std::lock_guard lock(mutex_);
    state_.text = std::move(text);
    state_.isDirty = true;
    state_.error.reset();
}

void DocumentFeatureModel::save(StateHandler handler) {
    std::string path;
    std::string text;
    {
        std::lock_guard lock(mutex_);
        path = state_.relativePath;
        text = state_.text;
        state_.isSaving = true;
        state_.error.reset();
    }
    coordinator_.writeFile(std::move(path), std::move(text), [this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        applyWrite(std::move(result), std::move(handler));
    });
}

void DocumentFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
}

DocumentFeatureState DocumentFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void DocumentFeatureModel::applyRead(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            if (auto file = decodeFileRead(*result.envelope)) {
                // A read can complete after the user has started editing the
                // buffer. Preserve those local changes instead of replacing
                // them with the older disk snapshot.
                if (!state_.isDirty && !state_.isSaving) {
                    state_.text = std::move(file->text);
                    state_.isDirty = false;
                }
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid file response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "File read failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void DocumentFeatureModel::applyWrite(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isSaving = false;
        if (result.envelope && result.envelope->ok && decodeFileWrite(*result.envelope)) {
            state_.isDirty = false;
            state_.error.reset();
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::ParseFailed, "Invalid file write response", std::nullopt};
        }
    }
    if (handler) handler(state());
}

} // namespace lithe::windows::app
