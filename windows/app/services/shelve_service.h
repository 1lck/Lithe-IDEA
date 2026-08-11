#pragma once

#include "git_workflow_types.h"
#include "ports.h"

#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

/// Versioned Lithe Shelf storage: staged and working-tree patches stay separate
/// so restore can replay index then worktree, and keep the entry on failure.
class ShelveService final {
public:
    explicit ShelveService(FileStorage& storage);

    std::vector<GitShelfEntry> entries(const std::string& repositoryRoot) const;
    std::optional<GitShelfEntry> save(const std::string& repositoryRoot,
                                      std::string message,
                                      std::vector<std::string> paths,
                                      std::string stagedPatch,
                                      std::string workingPatch);
    bool remove(const std::string& repositoryRoot, const GitShelfEntry& entry);

private:
    FileStorage& storage_;

    static std::string stableIdentifier(const std::string& repositoryRoot);
    std::string directoryPath(const std::string& repositoryRoot) const;
    std::string filePath(const std::string& repositoryRoot, const std::string& id) const;
};

} // namespace lithe::windows::app
