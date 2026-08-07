#pragma once

#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>

namespace lithe::windows::app {

struct ReplacementFeatureState {
    std::optional<ReplacementPreviewDto> preview;
    std::optional<CoreError> error;
    bool isLoading = false;
};

class ReplacementFeatureModel final {
public:
    using StateHandler = std::function<void(ReplacementFeatureState)>;

    explicit ReplacementFeatureModel(WorkbenchCoordinator& coordinator);

    void preview(ReplacementPreviewRequestDto request, StateHandler handler = {});
    void resetForWorkspace();
    ReplacementFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    ReplacementFeatureState state_;

    void apply(WorkspaceOperationResult result, StateHandler handler);
};

} // namespace lithe::windows::app
