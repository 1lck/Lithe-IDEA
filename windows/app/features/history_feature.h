#pragma once

#include "ports.h"
#include "workbench_coordinator.h"

#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

struct HistoryFeatureState {
    std::optional<HistoryEntriesDto> entries;
    std::optional<HistoryContentDto> content;
    std::optional<HistoryEntryDto> recordedEntry;
    std::optional<CoreError> error;
    bool isLoadingEntries = false;
    bool isLoadingContent = false;
    bool isRecording = false;
    bool isRelocating = false;
};

class HistoryFeatureModel final {
public:
    using StateHandler = std::function<void(HistoryFeatureState)>;

    HistoryFeatureModel(WorkbenchCoordinator& coordinator, FileStorage& storage);

    void loadEntries(std::optional<std::string> relativePath = std::nullopt,
                     StateHandler handler = {});
    void record(std::string relativePath,
                std::string reason,
                std::optional<std::string> content = std::nullopt,
                bool pruneExpired = true,
                StateHandler handler = {});
    void loadContent(std::string contentPath, StateHandler handler = {});
    void relocate(std::string sourcePath,
                  std::string destinationPath,
                  StateHandler handler = {});
    void setVisibilityRules(std::vector<std::string> hiddenDirectoryNames,
                            std::vector<std::string> hiddenFilePatterns);
    void resetForWorkspace();
    HistoryFeatureState state() const;

private:
    WorkbenchCoordinator& coordinator_;
    FileStorage& storage_;
    mutable std::mutex mutex_;
    HistoryFeatureState state_;
    std::vector<std::string> hiddenDirectoryNames_;
    std::vector<std::string> hiddenFilePatterns_;

    std::optional<std::string> localHistoryRoot() const;
    void fail(StateHandler handler, CoreError error);
    void applyEntries(WorkspaceOperationResult result, StateHandler handler);
    void applyRecord(WorkspaceOperationResult result, StateHandler handler);
    void applyContent(WorkspaceOperationResult result, StateHandler handler);
    void applyRelocate(WorkspaceOperationResult result, StateHandler handler);

    static std::string stableIdentifier(std::string_view value);
};

} // namespace lithe::windows::app
