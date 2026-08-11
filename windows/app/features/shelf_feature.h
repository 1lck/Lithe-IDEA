#pragma once

#include "ports.h"
#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>

namespace lithe::windows::app {

struct ShelfFeatureState {
    std::optional<ShelfListDto> shelves;
    std::optional<ShelfCreateDto> created;
    std::optional<ShelfRestoreDto> restored;
    std::optional<ShelfDeleteDto> deleted;
    std::optional<CoreError> error;
    bool isLoading = false;
    bool isCreating = false;
    bool isRestoring = false;
    bool isDeleting = false;
};

class ShelfFeatureModel final {
public:
    using StateHandler = std::function<void(ShelfFeatureState)>;

    ShelfFeatureModel(WorkbenchCoordinator& coordinator,
                      FileStorage& storage,
                      std::string dataDirectory = {});

    void load(StateHandler handler = {});
    void create(std::string label,
                std::string stagedPatch,
                std::string workingTreePatch,
                StateHandler handler = {});
    void restore(std::string id, StateHandler handler = {});
    void remove(std::string id, StateHandler handler = {});
    void resetForWorkspace();
    ShelfFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    FileStorage& storage_;
    std::string dataDirectory_;
    mutable std::mutex mutex_;
    ShelfFeatureState state_;

    std::optional<std::string> storageRoot() const;
    void applyList(WorkspaceOperationResult result, StateHandler handler);
    void applyCreate(WorkspaceOperationResult result, StateHandler handler);
    void applyRestore(WorkspaceOperationResult result, StateHandler handler);
    void applyDelete(WorkspaceOperationResult result, StateHandler handler);
};

}
