#include "git_watcher_freeze.h"

namespace lithe::windows::app {

void GitWatcherFreezeController::setFlushHandler(FlushHandler handler) {
    std::lock_guard lock(mutex_);
    flush_ = std::move(handler);
}

void GitWatcherFreezeController::begin() {
    std::lock_guard lock(mutex_);
    ++depth_;
}

bool GitWatcherFreezeController::end() {
    FlushHandler flush;
    std::vector<DirectoryChangeSource::Change> pending;
    {
        std::lock_guard lock(mutex_);
        if (depth_ == 0) return false;
        --depth_;
        if (depth_ != 0) return false;
        pending = std::move(pending_);
        pending_.clear();
        flush = flush_;
    }
    if (flush) flush(std::move(pending));
    return true;
}

bool GitWatcherFreezeController::isFrozen() const {
    std::lock_guard lock(mutex_);
    return depth_ > 0;
}

std::uint32_t GitWatcherFreezeController::depth() const {
    std::lock_guard lock(mutex_);
    return depth_;
}

void GitWatcherFreezeController::noteChanges(
    std::vector<DirectoryChangeSource::Change> changes) {
    FlushHandler flush;
    {
        std::lock_guard lock(mutex_);
        if (depth_ > 0) {
            pending_.insert(pending_.end(),
                            std::make_move_iterator(changes.begin()),
                            std::make_move_iterator(changes.end()));
            return;
        }
        flush = flush_;
    }
    if (flush) flush(std::move(changes));
}

void GitWatcherFreezeController::reset() {
    std::lock_guard lock(mutex_);
    depth_ = 0;
    pending_.clear();
}

} // namespace lithe::windows::app
