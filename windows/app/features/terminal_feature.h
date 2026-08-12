#pragma once

#include "terminal_buffer.h"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace lithe::windows::app {

enum class TerminalSessionStatus {
    Stopped,
    Starting,
    Running,
    Exited,
};

struct TerminalSessionSnapshot {
    std::string id;
    std::string title;
    std::string shellPath;
    std::string workingDirectory;
    TerminalSessionStatus status = TerminalSessionStatus::Stopped;
    std::optional<int> exitCode;
};

struct TerminalFeatureState {
    std::vector<TerminalSessionSnapshot> sessions;
    std::optional<std::string> activeSessionID;
    std::uint64_t revision = 0;
};

class TerminalFeatureModel final {
public:
    std::string create(std::string shellPath, std::string workingDirectory);
    bool select(std::string_view id);
    bool remove(std::string_view id);
    bool setShell(std::string_view id, std::string shellPath);
    bool markStarting(std::string_view id);
    bool markRunning(std::string_view id);
    bool markStopped(std::string_view id);
    bool markExited(std::string_view id, std::optional<int> exitCode = std::nullopt);
    bool appendOutput(std::string_view id, std::string_view output);
    bool clearOutput(std::string_view id);
    std::string output(std::string_view id, std::size_t maximumCharacters = 500'000) const;
    std::optional<TerminalSessionSnapshot> session(std::string_view id) const;
    TerminalFeatureState state() const;
    void reset();

private:
    struct Session {
        TerminalSessionSnapshot snapshot;
        algorithms::TerminalBuffer output;
    };

    mutable std::mutex mutex_;
    std::unordered_map<std::string, Session> sessions_;
    std::vector<std::string> order_;
    std::optional<std::string> activeSessionID_;
    std::uint64_t serial_ = 0;
    std::uint64_t revision_ = 0;

    bool setStatus(std::string_view id, TerminalSessionStatus status,
                   std::optional<int> exitCode);
};

} // namespace lithe::windows::app
