#pragma once

#include "core_dto.h"

#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

enum class GitIntegrationOperation {
    Merge,
    Rebase,
    CherryPick,
    Revert,
};

enum class GitCheckoutConflictStrategy {
    Smart,
    Force,
};

enum class GitSaveChangesPolicy {
    Stash,
    Shelve,
};

enum class GitPullStrategy {
    FfOnly,
    Merge,
    Rebase,
};

inline const char* integrationOperationId(GitIntegrationOperation operation) {
    switch (operation) {
    case GitIntegrationOperation::Merge: return "merge";
    case GitIntegrationOperation::Rebase: return "rebase";
    case GitIntegrationOperation::CherryPick: return "cherryPick";
    case GitIntegrationOperation::Revert: return "revert";
    }
    return "merge";
}

inline const char* integrationOperationTitle(GitIntegrationOperation operation) {
    switch (operation) {
    case GitIntegrationOperation::Merge: return "Merge";
    case GitIntegrationOperation::Rebase: return "Rebase";
    case GitIntegrationOperation::CherryPick: return "Cherry-pick";
    case GitIntegrationOperation::Revert: return "Revert";
    }
    return "Merge";
}

struct GitCheckoutConflictRequest {
    std::string reference;
    std::string referenceKind;
    std::string shortName;
    std::vector<std::string> blockingPaths;
    std::vector<std::string> dirtyDocumentPaths;
};

struct GitIntegrationConflictRequest {
    std::string reference;
    std::string displayName;
    GitIntegrationOperation operation = GitIntegrationOperation::Merge;
    std::vector<std::string> blockingPaths;
    bool blocksEntirely = false;
    std::vector<std::string> dirtyDocumentPaths;
};

struct GitPullStrategyRequest {
    std::string upstream;
    std::uint64_t ahead = 0;
    std::uint64_t behind = 0;
    bool hasLocalChanges = false;
};

struct GitStashRestoreConflictRequest {
    std::string stashReference;
    std::vector<std::string> conflictedPaths;
    std::string operationTitle;
};

struct GitDeferredSavedChanges {
    std::optional<std::string> stashReference;
    std::optional<std::string> shelfId;
    std::string operationTitle;
};

struct GitShelfEntry {
    std::string id;
    std::string message;
    std::int64_t createdAt = 0; // Unix seconds
    std::vector<std::string> paths;
    std::string stagedPatch;
    std::string workingPatch;
};

struct GitOperationState {
    std::string kind;
    std::optional<std::string> reference;
    std::optional<std::uint64_t> step;
    std::optional<std::uint64_t> total;
    std::vector<std::string> conflictedPaths;

    bool hasConflicts() const { return !conflictedPaths.empty(); }
    bool canSkip() const { return kind == "rebase"; }
    bool isActive() const { return !kind.empty(); }
};

inline std::optional<GitOperationState> toOperationState(
    const GitOperationStateDto& dto) {
    if (dto.kind.empty()) return std::nullopt;
    return GitOperationState{
        dto.kind, dto.reference, dto.step, dto.total, dto.conflictedPaths};
}

} // namespace lithe::windows::app
