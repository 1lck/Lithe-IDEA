#include "search_feature.h"

namespace lithe::windows::app {

SearchFeatureModel::SearchFeatureModel(WorkbenchCoordinator& coordinator)
    : coordinator_(coordinator) {}

void SearchFeatureModel::search(std::string query, StateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        state_.query = query;
        state_.isLoading = true;
        state_.error.reset();
    }
    coordinator_.search(std::move(query), [this, handler = std::move(handler)](
        WorkspaceOperationResult result) mutable {
        apply(std::move(result), std::move(handler));
    });
}

void SearchFeatureModel::searchEverywhere(std::string query,
                                          SearchEverywhereStateHandler handler) {
    {
        std::lock_guard lock(mutex_);
        searchEverywhereState_.query = query;
        searchEverywhereState_.matches.clear();
        searchEverywhereState_.isLoading = true;
        searchEverywhereState_.error.reset();
    }
    coordinator_.searchEverywhere(std::move(query),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
        applySearchEverywhere(std::move(result), std::move(handler));
    });
}

void SearchFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
    searchEverywhereState_ = {};
}

SearchFeatureState SearchFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

SearchEverywhereFeatureState SearchFeatureModel::searchEverywhereState() const {
    std::lock_guard lock(mutex_);
    return searchEverywhereState_;
}

void SearchFeatureModel::apply(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        state_.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            if (auto search = decodeSearchResponse(*result.envelope)) {
                state_.matches = std::move(search->matches);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid search response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "Search failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void SearchFeatureModel::applySearchEverywhere(WorkspaceOperationResult result,
                                               SearchEverywhereStateHandler handler) {
    if (result.stale) return;
    {
        std::lock_guard lock(mutex_);
        searchEverywhereState_.isLoading = false;
        if (result.envelope && result.envelope->ok) {
            if (auto search = decodeSearchResponse(*result.envelope)) {
                searchEverywhereState_.matches = std::move(search->matches);
                searchEverywhereState_.error.reset();
            } else {
                searchEverywhereState_.error = CoreError{
                    CoreErrorCode::ParseFailed,
                    "Invalid Search Everywhere response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            searchEverywhereState_.error = *error;
        } else {
            searchEverywhereState_.error = CoreError{
                CoreErrorCode::Unknown, "Search Everywhere failed", std::nullopt};
        }
    }
    if (handler) handler(searchEverywhereState());
}

} // namespace lithe::windows::app
