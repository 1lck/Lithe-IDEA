#include "workspace_write_lifecycle.h"

#include <utility>

namespace lithe::windows::app {

WorkspaceWriteLifecycle::Token WorkspaceWriteLifecycle::begin(
    bool preserveDeferredChanges) {
    std::lock_guard lock(mutex_);
    const auto token = ++serial_;
    if (activeTokens_.empty()) preserveDeferredForCycle_ = preserveDeferredChanges;
    else preserveDeferredForCycle_ = preserveDeferredForCycle_ || preserveDeferredChanges;
    activeTokens_.emplace(token, preserveDeferredChanges);
    return token;
}

WorkspaceWriteCompletion WorkspaceWriteLifecycle::end(
    Token token, bool requestRefresh) {
    std::lock_guard lock(mutex_);
    if (activeTokens_.erase(token) == 0) return {};
    refreshPending_ = refreshPending_ || requestRefresh;
    if (!activeTokens_.empty()) return {};

    WorkspaceWriteCompletion result;
    result.shouldRefresh = refreshPending_;
    result.deferredChanges.reserve(deferredOrder_.size());
    for (const auto& path : deferredOrder_) {
        if (const auto found = deferredByPath_.find(path); found != deferredByPath_.end()) {
            result.deferredChanges.push_back(found->second);
        }
    }
    deferredOrder_.clear();
    deferredByPath_.clear();
    refreshPending_ = false;
    if (!preserveDeferredForCycle_) {
        // The Win32 watcher batches for 350 ms. Keep application-owned writes
        // muted long enough for that trailing batch to arrive after the write callback.
        suppressChangesUntil_ = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(750);
    }
    preserveDeferredForCycle_ = false;
    return result;
}

bool WorkspaceWriteLifecycle::requestRefresh() {
    std::lock_guard lock(mutex_);
    if (activeTokens_.empty()) return true;
    refreshPending_ = true;
    return false;
}

std::optional<std::vector<DirectoryChangeSource::Change>>
WorkspaceWriteLifecycle::observeChanges(
    std::vector<DirectoryChangeSource::Change> changes) {
    std::lock_guard lock(mutex_);
    if (activeTokens_.empty()) {
        if (suppressChangesUntil_ &&
            std::chrono::steady_clock::now() < *suppressChangesUntil_) {
            return std::nullopt;
        }
        suppressChangesUntil_.reset();
        return changes;
    }
    if (preserveDeferredForCycle_) mergeChanges(std::move(changes));
    refreshPending_ = true;
    return std::nullopt;
}

bool WorkspaceWriteLifecycle::isFrozen() const {
    std::lock_guard lock(mutex_);
    return !activeTokens_.empty();
}

std::size_t WorkspaceWriteLifecycle::depth() const {
    std::lock_guard lock(mutex_);
    return activeTokens_.size();
}

void WorkspaceWriteLifecycle::reset() {
    std::lock_guard lock(mutex_);
    activeTokens_.clear();
    deferredOrder_.clear();
    deferredByPath_.clear();
    refreshPending_ = false;
    preserveDeferredForCycle_ = false;
    suppressChangesUntil_.reset();
}

void WorkspaceWriteLifecycle::mergeChanges(
    std::vector<DirectoryChangeSource::Change> changes) {
    for (auto& change : changes) {
        if (change.kind == DirectoryChangeSource::ChangeKind::RescanRequired) {
            deferredOrder_.clear();
            deferredByPath_.clear();
            deferredOrder_.push_back(".");
            deferredByPath_.emplace(".", std::move(change));
            continue;
        }
        if (deferredByPath_.contains(".")) continue;
        if (!deferredByPath_.contains(change.path)) deferredOrder_.push_back(change.path);
        deferredByPath_[change.path] = std::move(change);
    }
}

} // namespace lithe::windows::app
