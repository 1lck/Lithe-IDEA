#pragma once

#include "workbench_coordinator.h"

#include <filesystem>
#include <functional>
#include <mutex>
#include <optional>

namespace lithe::windows::app {

struct WorkspaceFeatureState {
    std::optional<std::filesystem::path> root;
    std::optional<WorkspaceSnapshotDto> snapshot;
    std::optional<CoreError> error;
    bool isLoading = false;
};

class WorkspaceFeatureModel final {
public:
    using StateHandler = std::function<void(WorkspaceFeatureState)>;

    explicit WorkspaceFeatureModel(WorkbenchCoordinator& coordinator);

    void open(std::filesystem::path root, StateHandler handler = {});
    void refresh(StateHandler handler = {});
    void close();
    void resetForWorkspace();
    WorkspaceFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    WorkspaceFeatureState state_;

    void apply(WorkspaceOperationResult result, StateHandler handler);
};

} // namespace lithe::windows::app
