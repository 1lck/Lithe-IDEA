#pragma once

#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>

namespace lithe::windows::app {

struct DocumentFeatureState {
    std::string relativePath;
    std::string text;
    std::optional<CoreError> error;
    bool isLoading = false;
    bool isSaving = false;
    bool isDirty = false;
};

class DocumentFeatureModel final {
public:
    using StateHandler = std::function<void(DocumentFeatureState)>;

    explicit DocumentFeatureModel(WorkbenchCoordinator& coordinator);

    void open(std::string relativePath, StateHandler handler = {});
    void setText(std::string text);
    void save(StateHandler handler = {});
    void resetForWorkspace();
    DocumentFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    DocumentFeatureState state_;

    void applyRead(WorkspaceOperationResult result, StateHandler handler);
    void applyWrite(WorkspaceOperationResult result, StateHandler handler);
};

} // namespace lithe::windows::app
