#pragma once

#include "workbench_coordinator.h"

#include <functional>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>

namespace lithe::windows::app {

struct DocumentFeatureState {
    std::string relativePath;
    std::string text;
    std::optional<CoreError> error;
    std::optional<std::uint64_t> diskFingerprint;
    bool isLoading = false;
    bool isSaving = false;
    bool isDirty = false;
    bool hasExternalConflict = false;
};

class DocumentFeatureModel final {
public:
    using StateHandler = std::function<void(DocumentFeatureState)>;

    explicit DocumentFeatureModel(WorkbenchCoordinator& coordinator);

    void open(std::string relativePath, StateHandler handler = {});
    void setText(std::string text);
    void save(StateHandler handler = {});
    void markExternalConflict(std::string relativePath, StateHandler handler = {});
    void keepEditorVersion(StateHandler handler = {});
    void resetForWorkspace();
    DocumentFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    mutable std::mutex mutex_;
    DocumentFeatureState state_;

    void applyRead(WorkspaceOperationResult result, StateHandler handler);
    void applyWrite(WorkspaceOperationResult result,
                    std::string savedText,
                    StateHandler handler);
    static std::uint64_t fingerprint(std::string_view text);
};

} // namespace lithe::windows::app
