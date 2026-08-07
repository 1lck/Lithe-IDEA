#pragma once

#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct SearchFeatureState {
    std::string query;
    std::vector<SearchMatchDto> matches;
    std::optional<CoreError> error;
    bool isLoading = false;
};

struct SearchEverywhereFeatureState {
    std::string query;
    std::vector<SearchMatchDto> matches;
    std::optional<CoreError> error;
    bool isLoading = false;
};

class SearchFeatureModel final {
public:
    using StateHandler = std::function<void(SearchFeatureState)>;

    explicit SearchFeatureModel(WorkbenchCoordinator& coordinator);

    void search(std::string query, StateHandler handler = {});
    using SearchEverywhereStateHandler = std::function<void(SearchEverywhereFeatureState)>;
    void searchEverywhere(std::string query, SearchEverywhereStateHandler handler = {});
    void resetForWorkspace();
    SearchFeatureState state() const;
    SearchEverywhereFeatureState searchEverywhereState() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    SearchFeatureState state_;
    SearchEverywhereFeatureState searchEverywhereState_;

    void apply(WorkspaceOperationResult result, StateHandler handler);
    void applySearchEverywhere(WorkspaceOperationResult result,
                               SearchEverywhereStateHandler handler);
};

} // namespace lithe::windows::app
