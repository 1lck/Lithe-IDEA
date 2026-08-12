#include "terminal_feature.h"

#include <algorithm>
#include <utility>

namespace lithe::windows::app {

std::string TerminalFeatureModel::create(
    std::string shellPath, std::string workingDirectory) {
    std::lock_guard lock(mutex_);
    const auto number = ++serial_;
    const auto id = "terminal-" + std::to_string(number);
    TerminalSessionSnapshot snapshot;
    snapshot.id = id;
    snapshot.title = "Terminal " + std::to_string(number);
    snapshot.shellPath = std::move(shellPath);
    snapshot.workingDirectory = std::move(workingDirectory);
    sessions_.emplace(id, Session{std::move(snapshot), {}});
    order_.push_back(id);
    activeSessionID_ = id;
    ++revision_;
    return id;
}

bool TerminalFeatureModel::select(std::string_view id) {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    if (found == sessions_.end()) return false;
    activeSessionID_ = found->first;
    ++revision_;
    return true;
}

bool TerminalFeatureModel::remove(std::string_view id) {
    std::lock_guard lock(mutex_);
    const auto key = std::string(id);
    if (sessions_.erase(key) == 0) return false;
    order_.erase(std::remove(order_.begin(), order_.end(), key), order_.end());
    if (activeSessionID_ && *activeSessionID_ == key) {
        activeSessionID_ = order_.empty()
            ? std::nullopt : std::optional<std::string>(order_.front());
    }
    ++revision_;
    return true;
}

bool TerminalFeatureModel::setShell(std::string_view id, std::string shellPath) {
    if (shellPath.empty() || shellPath.find('\0') != std::string::npos) return false;
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    if (found == sessions_.end()) return false;
    found->second.snapshot.shellPath = std::move(shellPath);
    ++revision_;
    return true;
}

bool TerminalFeatureModel::setStatus(std::string_view id,
                                     TerminalSessionStatus status,
                                     std::optional<int> exitCode) {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    if (found == sessions_.end()) return false;
    found->second.snapshot.status = status;
    found->second.snapshot.exitCode = exitCode;
    ++revision_;
    return true;
}

bool TerminalFeatureModel::markStarting(std::string_view id) {
    return setStatus(id, TerminalSessionStatus::Starting, std::nullopt);
}

bool TerminalFeatureModel::markRunning(std::string_view id) {
    return setStatus(id, TerminalSessionStatus::Running, std::nullopt);
}

bool TerminalFeatureModel::markStopped(std::string_view id) {
    return setStatus(id, TerminalSessionStatus::Stopped, std::nullopt);
}

bool TerminalFeatureModel::markExited(std::string_view id, std::optional<int> exitCode) {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    if (found == sessions_.end()) return false;
    if (found->second.snapshot.status == TerminalSessionStatus::Stopped) return false;
    found->second.snapshot.status = TerminalSessionStatus::Exited;
    found->second.snapshot.exitCode = exitCode;
    ++revision_;
    return true;
}

bool TerminalFeatureModel::appendOutput(std::string_view id, std::string_view output) {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    if (found == sessions_.end()) return false;
    found->second.output.append(output);
    return true;
}

bool TerminalFeatureModel::clearOutput(std::string_view id) {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    if (found == sessions_.end()) return false;
    found->second.output.reset();
    return true;
}

std::string TerminalFeatureModel::output(
    std::string_view id, std::size_t maximumCharacters) const {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    return found == sessions_.end()
        ? std::string{} : found->second.output.render(maximumCharacters);
}

std::optional<TerminalSessionSnapshot> TerminalFeatureModel::session(std::string_view id) const {
    std::lock_guard lock(mutex_);
    const auto found = sessions_.find(std::string(id));
    return found == sessions_.end()
        ? std::nullopt : std::optional<TerminalSessionSnapshot>(found->second.snapshot);
}

TerminalFeatureState TerminalFeatureModel::state() const {
    std::lock_guard lock(mutex_);
    TerminalFeatureState result;
    result.activeSessionID = activeSessionID_;
    result.revision = revision_;
    result.sessions.reserve(order_.size());
    for (const auto& id : order_) {
        if (const auto found = sessions_.find(id); found != sessions_.end()) {
            result.sessions.push_back(found->second.snapshot);
        }
    }
    return result;
}

void TerminalFeatureModel::reset() {
    std::lock_guard lock(mutex_);
    sessions_.clear();
    order_.clear();
    activeSessionID_.reset();
    ++revision_;
}

} // namespace lithe::windows::app
