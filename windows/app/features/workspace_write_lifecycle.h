#pragma once

#include "ports.h"

#include <chrono>
#include <cstdint>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <vector>

namespace lithe::windows::app {

struct WorkspaceWriteCompletion {
    bool shouldRefresh = false;
    std::vector<DirectoryChangeSource::Change> deferredChanges;
};

class WorkspaceWriteLifecycle final {
public:
    using Token = std::uint64_t;

    Token begin(bool preserveDeferredChanges = true);
    WorkspaceWriteCompletion end(Token token, bool requestRefresh = true);
    bool requestRefresh();
    std::optional<std::vector<DirectoryChangeSource::Change>> observeChanges(
        std::vector<DirectoryChangeSource::Change> changes);
    bool isFrozen() const;
    std::size_t depth() const;
    void reset();

private:
    mutable std::mutex mutex_;
    std::uint64_t serial_ = 0;
    std::unordered_map<Token, bool> activeTokens_;
    std::vector<std::string> deferredOrder_;
    std::unordered_map<std::string, DirectoryChangeSource::Change> deferredByPath_;
    bool refreshPending_ = false;
    bool preserveDeferredForCycle_ = false;
    std::optional<std::chrono::steady_clock::time_point> suppressChangesUntil_;

    void mergeChanges(std::vector<DirectoryChangeSource::Change> changes);
};

} // namespace lithe::windows::app
