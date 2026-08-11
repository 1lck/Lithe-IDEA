#pragma once

#include "ports.h"

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace lithe::windows::app {

/// Nestable freeze for directory-watcher side effects during Git writes.
///
/// The watcher may keep receiving OS notifications; this controller only
/// suppresses applying them until the outermost Git operation ends, then
/// delivers accumulated paths once.
class GitWatcherFreezeController final {
public:
    using FlushHandler = std::function<void(std::vector<DirectoryChangeSource::Change>)>;

    void setFlushHandler(FlushHandler handler);

    void begin();
    /// Returns true when this call closed the outermost freeze and a flush ran
    /// (or was requested with an empty set).
    bool end();

    bool isFrozen() const;
    std::uint32_t depth() const;

    /// When frozen, accumulate; otherwise forward immediately via the flush handler.
    void noteChanges(std::vector<DirectoryChangeSource::Change> changes);

    void reset();

private:
    mutable std::mutex mutex_;
    std::uint32_t depth_ = 0;
    std::vector<DirectoryChangeSource::Change> pending_;
    FlushHandler flush_;
};

} // namespace lithe::windows::app
