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
        state_.hasExternalConflict = false;
        state_.diskFingerprint.reset();
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
    state_.isDirty = !state_.diskFingerprint ||
        fingerprint(state_.text) != *state_.diskFingerprint;
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
    coordinator_.writeFile(std::move(path), text,
        [this, savedText = std::move(text), handler = std::move(handler)](
            WorkspaceOperationResult result) mutable {
        applyWrite(std::move(result), std::move(savedText), std::move(handler));
    });
}

void DocumentFeatureModel::markExternalConflict(
    std::string relativePath, StateHandler handler) {
    bool changed = false;
    {
        std::lock_guard lock(mutex_);
        if (state_.relativePath == relativePath && state_.isDirty) {
            state_.hasExternalConflict = true;
            changed = true;
        }
    }
    if (changed && handler) handler(state());
}

void DocumentFeatureModel::keepEditorVersion(StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.hasExternalConflict = false;
    }
    if (handler) handler(state());
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
                    state_.text = file->text;
                }
                state_.diskFingerprint = fingerprint(file->text);
                state_.isDirty = fingerprint(state_.text) != *state_.diskFingerprint;
                state_.hasExternalConflict = false;
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

void DocumentFeatureModel::applyWrite(WorkspaceOperationResult result,
                                      std::string savedText,
                                      StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isSaving = false;
        if (result.envelope && result.envelope->ok && decodeFileWrite(*result.envelope)) {
            state_.diskFingerprint = fingerprint(savedText);
            state_.isDirty = fingerprint(state_.text) != *state_.diskFingerprint;
            state_.hasExternalConflict = false;
            state_.error.reset();
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::ParseFailed, "Invalid file write response", std::nullopt};
        }
    }
    if (handler) handler(state());
}

std::uint64_t DocumentFeatureModel::fingerprint(std::string_view text) {
    std::uint64_t value = 14695981039346656037ULL;
    for (const unsigned char byte : text) {
        value ^= byte;
        value *= 1099511628211ULL;
    }
    return value;
}

} // namespace lithe::windows::app
