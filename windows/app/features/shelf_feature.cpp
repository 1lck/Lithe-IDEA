#include "shelf_feature.h"

namespace lithe::windows::app {

ShelfFeatureModel::ShelfFeatureModel(WorkbenchCoordinator& coordinator,
                                     FileStorage& storage,
                                     std::string dataDirectory)
    : coordinator_(coordinator), storage_(storage), dataDirectory_(std::move(dataDirectory)) {}

void ShelfFeatureModel::load(StateHandler handler) {
    const auto root = storageRoot();
    if (!root) {
        if (handler) handler(ShelfFeatureState{.error = CoreError{
            CoreErrorCode::WorkspaceNotFound, "Shelf storage is unavailable", std::nullopt}});
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = true;
        state_.error.reset();
    }
    coordinator_.shelfList(*root, [this, handler = std::move(handler)](auto result) mutable {
        applyList(std::move(result), std::move(handler));
    });
}

void ShelfFeatureModel::create(std::string label,
                               std::string stagedPatch,
                               std::string workingTreePatch,
                               StateHandler handler) {
    const auto root = storageRoot();
    if (!root) {
        if (handler) handler(ShelfFeatureState{.error = CoreError{
            CoreErrorCode::WorkspaceNotFound, "Shelf storage is unavailable", std::nullopt}});
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isCreating = true;
        state_.error.reset();
    }
    coordinator_.shelfCreate(*root, std::move(label), std::move(stagedPatch),
                             std::move(workingTreePatch),
                             [this, handler = std::move(handler)](auto result) mutable {
                                 applyCreate(std::move(result), std::move(handler));
                             });
}

void ShelfFeatureModel::restore(std::string id, StateHandler handler) {
    const auto root = storageRoot();
    if (!root) {
        if (handler) handler(ShelfFeatureState{.error = CoreError{
            CoreErrorCode::WorkspaceNotFound, "Shelf storage is unavailable", std::nullopt}});
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isRestoring = true;
        state_.error.reset();
    }
    coordinator_.shelfRestore(*root, std::move(id),
                              [this, handler = std::move(handler)](auto result) mutable {
                                  applyRestore(std::move(result), std::move(handler));
                              });
}

void ShelfFeatureModel::remove(std::string id, StateHandler handler) {
    const auto root = storageRoot();
    if (!root) {
        if (handler) handler(ShelfFeatureState{.error = CoreError{
            CoreErrorCode::WorkspaceNotFound, "Shelf storage is unavailable", std::nullopt}});
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isDeleting = true;
        state_.error.reset();
    }
    coordinator_.shelfDelete(*root, std::move(id),
                             [this, handler = std::move(handler)](auto result) mutable {
                                 applyDelete(std::move(result), std::move(handler));
                             });
}

void ShelfFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
}

ShelfFeatureState ShelfFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

std::optional<std::string> ShelfFeatureModel::storageRoot() const {
    if (!dataDirectory_.empty()) {
        std::string normalized = dataDirectory_;
        for (auto& character : normalized) {
            if (character == '\\') character = '/';
        }
        while (!normalized.empty() && normalized.back() == '/') normalized.pop_back();
        if (!normalized.empty()) return normalized;
    }
    const auto applicationSupport = storage_.applicationSupportDirectory();
    if (applicationSupport.empty()) return std::nullopt;
    std::string support = applicationSupport;
    for (auto& character : support) {
        if (character == '\\') character = '/';
    }
    while (!support.empty() && support.back() == '/') support.pop_back();
    return support + "/lithe";
}

void ShelfFeatureModel::applyList(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        {
            std::lock_guard lock(mutex_);
            state_.isLoading = false;
        }
        if (handler) handler(state());
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            state_.shelves = decodeShelfList(*result.envelope);
            if (!state_.shelves) {
                state_.error = CoreError{CoreErrorCode::ParseFailed,
                                         "Invalid Shelf list response", std::nullopt};
            } else {
                state_.error.reset();
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Shelf list failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void ShelfFeatureModel::applyCreate(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        {
            std::lock_guard lock(mutex_);
            state_.isCreating = false;
        }
        if (handler) handler(state());
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isCreating = false;
        if (result.envelope && result.envelope->ok) {
            state_.created = decodeShelfCreate(*result.envelope);
            if (!state_.created) {
                state_.error = CoreError{CoreErrorCode::ParseFailed,
                                         "Invalid Shelf create response", std::nullopt};
            } else {
                state_.error.reset();
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Shelf create failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void ShelfFeatureModel::applyRestore(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        {
            std::lock_guard lock(mutex_);
            state_.isRestoring = false;
        }
        if (handler) handler(state());
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isRestoring = false;
        if (result.envelope && result.envelope->ok) {
            state_.restored = decodeShelfRestore(*result.envelope);
            if (!state_.restored) {
                state_.error = CoreError{CoreErrorCode::ParseFailed,
                                         "Invalid Shelf restore response", std::nullopt};
            } else {
                state_.error.reset();
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Shelf restore failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void ShelfFeatureModel::applyDelete(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) {
        {
            std::lock_guard lock(mutex_);
            state_.isDeleting = false;
        }
        if (handler) handler(state());
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isDeleting = false;
        if (result.envelope && result.envelope->ok) {
            state_.deleted = decodeShelfDelete(*result.envelope);
            if (!state_.deleted) {
                state_.error = CoreError{CoreErrorCode::ParseFailed,
                                         "Invalid Shelf delete response", std::nullopt};
            } else {
                state_.error.reset();
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Shelf delete failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

}
