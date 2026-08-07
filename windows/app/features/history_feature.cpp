#include "history_feature.h"

#include <filesystem>

namespace lithe::windows::app {

HistoryFeatureModel::HistoryFeatureModel(WorkbenchCoordinator& coordinator,
                                         FileStorage& storage)
    : coordinator_(coordinator), storage_(storage) {}

void HistoryFeatureModel::loadEntries(std::optional<std::string> relativePath,
                                      StateHandler handler) {
    const auto storageRoot = localHistoryRoot();
    if (!storageRoot) {
        fail(std::move(handler), CoreError{
            CoreErrorCode::WorkspaceNotFound, "No workspace is open", std::nullopt});
        return;
    }
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingEntries = true;
        state_.error.reset();
        hiddenDirectoryNames = hiddenDirectoryNames_;
        hiddenFilePatterns = hiddenFilePatterns_;
    }
    coordinator_.historyEntries(
        *storageRoot, std::move(relativePath), std::move(hiddenDirectoryNames),
        std::move(hiddenFilePatterns),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyEntries(std::move(result), std::move(handler));
        });
}

void HistoryFeatureModel::record(std::string relativePath,
                                 std::string reason,
                                 std::optional<std::string> content,
                                 bool pruneExpired,
                                 StateHandler handler) {
    const auto storageRoot = localHistoryRoot();
    if (!storageRoot) {
        fail(std::move(handler), CoreError{
            CoreErrorCode::WorkspaceNotFound, "No workspace is open", std::nullopt});
        return;
    }
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
    {
        std::lock_guard lock(mutex_);
        state_.isRecording = true;
        state_.error.reset();
        hiddenDirectoryNames = hiddenDirectoryNames_;
        hiddenFilePatterns = hiddenFilePatterns_;
    }
    coordinator_.historyRecord(
        *storageRoot, std::move(relativePath), std::move(reason), std::move(content),
        pruneExpired, std::move(hiddenDirectoryNames), std::move(hiddenFilePatterns),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyRecord(std::move(result), std::move(handler));
        });
}

void HistoryFeatureModel::loadContent(std::string contentPath, StateHandler handler) {
    const auto storageRoot = localHistoryRoot();
    if (!storageRoot) {
        fail(std::move(handler), CoreError{
            CoreErrorCode::WorkspaceNotFound, "No workspace is open", std::nullopt});
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingContent = true;
        state_.error.reset();
    }
    coordinator_.historyContent(
        *storageRoot, std::move(contentPath),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyContent(std::move(result), std::move(handler));
        });
}

void HistoryFeatureModel::relocate(std::string sourcePath,
                                   std::string destinationPath,
                                   StateHandler handler) {
    const auto storageRoot = localHistoryRoot();
    if (!storageRoot) {
        fail(std::move(handler), CoreError{
            CoreErrorCode::WorkspaceNotFound, "No workspace is open", std::nullopt});
        return;
    }
    {
        std::lock_guard lock(mutex_);
        state_.isRelocating = true;
        state_.error.reset();
    }
    coordinator_.historyRelocate(
        *storageRoot, std::move(sourcePath), std::move(destinationPath),
        [this, handler = std::move(handler)](WorkspaceOperationResult result) mutable {
            applyRelocate(std::move(result), std::move(handler));
        });
}

void HistoryFeatureModel::setVisibilityRules(
    std::vector<std::string> hiddenDirectoryNames,
    std::vector<std::string> hiddenFilePatterns) {
    std::lock_guard lock(mutex_);
    hiddenDirectoryNames_ = std::move(hiddenDirectoryNames);
    hiddenFilePatterns_ = std::move(hiddenFilePatterns);
}

HistoryFeatureState HistoryFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void HistoryFeatureModel::resetForWorkspace() {
    std::lock_guard lock(mutex_);
    state_ = {};
}

std::optional<std::string> HistoryFeatureModel::localHistoryRoot() const {
    const auto paths = coordinator_.workspacePaths();
    if (!paths) return std::nullopt;
    const auto applicationSupport = storage_.applicationSupportDirectory();
    if (applicationSupport.empty()) return std::nullopt;
    const auto root = paths->root().generic_u8string();
    const std::string rootUtf8(reinterpret_cast<const char*>(root.data()), root.size());
    std::string support = applicationSupport;
    for (auto& character : support) {
        if (character == '\\') character = '/';
    }
    while (!support.empty() && support.back() == '/') support.pop_back();
    return support + "/LocalHistory/" + stableIdentifier(rootUtf8);
}

void HistoryFeatureModel::fail(StateHandler handler, CoreError error) {
    {
        std::lock_guard lock(mutex_);
        state_.isLoadingEntries = false;
        state_.isLoadingContent = false;
        state_.isRecording = false;
        state_.isRelocating = false;
        state_.error = std::move(error);
    }
    if (handler) handler(state());
}

void HistoryFeatureModel::applyEntries(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingEntries = false;
        if (result.envelope && result.envelope->ok) {
            if (auto entries = decodeHistoryEntries(*result.envelope)) {
                state_.entries = std::move(*entries);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid history entries response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "History entries failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void HistoryFeatureModel::applyRecord(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isRecording = false;
        if (result.envelope && result.envelope->ok) {
            if (auto record = decodeHistoryRecord(*result.envelope)) {
                state_.recordedEntry = record->entry;
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid history record response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "History record failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void HistoryFeatureModel::applyContent(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isLoadingContent = false;
        if (result.envelope && result.envelope->ok) {
            if (auto content = decodeHistoryContent(*result.envelope)) {
                state_.content = std::move(*content);
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid history content response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "History content failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

void HistoryFeatureModel::applyRelocate(WorkspaceOperationResult result, StateHandler handler) {
    if (result.stale) return;
    if (!result.stale) {
        std::lock_guard lock(mutex_);
        state_.isRelocating = false;
        if (result.envelope && result.envelope->ok) {
            if (auto relocated = decodeHistoryRelocate(*result.envelope); relocated && relocated->relocated) {
                state_.error.reset();
            } else {
                state_.error = CoreError{
                    CoreErrorCode::ParseFailed, "Invalid history relocate response", std::nullopt};
            }
        } else if (const auto error = result.coreError()) {
            state_.error = *error;
        } else {
            state_.error = CoreError{CoreErrorCode::Unknown, "History relocate failed", std::nullopt};
        }
    }
    if (handler) handler(state());
}

std::string HistoryFeatureModel::stableIdentifier(std::string_view value) {
    std::uint64_t hash = 14'695'981'039'346'656'037ULL;
    for (const auto byte : value) {
        hash ^= static_cast<unsigned char>(byte);
        hash *= 1'099'511'628'211ULL;
    }
    return std::to_string(hash);
}

} // namespace lithe::windows::app
