#pragma once

#include "ports.h"
#include "terminal_session.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

// Owns the set of terminal sessions, the active session id, and a terminal
// epoch used to drop callbacks that outlive a workspace switch or shutdown.
//
// The model is the only thing the Qt layer talks to for terminals: it creates
// transports through the injected factory (so tests pass a fake), routes every
// session callback through the epoch check, and exposes scoped new/select/close/
// switch + Clear/Interrupt/Restart. Pure application logic: no Qt, no Win32.
class TerminalModel {
public:
    using TransportFactory = std::function<std::unique_ptr<TerminalTransport>()>;

    using OutputSink = TerminalSession::OutputSink;
    using ErrorSink = TerminalSession::ErrorSink;
    using StateSink = TerminalSession::StateSink;
    using SessionListSink = std::function<void()>;

    explicit TerminalModel(TransportFactory factory);
    ~TerminalModel();

    TerminalModel(const TerminalModel&) = delete;
    TerminalModel& operator=(const TerminalModel&) = delete;
    TerminalModel(TerminalModel&&) = delete;
    TerminalModel& operator=(TerminalModel&&) = delete;

    // Creates a session, launches it, and selects it. Returns the new id.
    std::string create(const TerminalShellSpec& shell,
                       const std::string& workingDirectory,
                       const std::map<std::string, std::string>& environment);

    bool select(const std::string& id);
    void close(const std::string& id);
    // Stops and removes every session. Used on close-project / workspace switch.
    void closeAll();
    // Stops everything and invalidates outstanding callbacks. Used on app exit.
    void shutdown();

    // Scoped actions; return false if the id is unknown. Actions affect only
    // the targeted session.
    bool send(const std::string& id, const std::string& input);
    bool interrupt(const std::string& id);
    bool clear(const std::string& id);
    bool restart(const std::string& id);

    std::vector<std::string> sessionIds() const;
    std::optional<std::string> currentId() const;
    // Best-effort lookup for immediate inspection (e.g. rendering). Lifetime is
    // tied to the model; do not retain across mutations.
    const TerminalSession* find(const std::string& id) const;
    TerminalSession* find(const std::string& id);
    std::uint64_t epoch() const noexcept { return epoch_.load(); }

    void setSinks(OutputSink output, ErrorSink error, StateSink state, SessionListSink listChanged);

private:
    std::string allocateId();
    void attachHandlers(TerminalSession& session);
    void notifyListChanged();

    TransportFactory factory_;
    mutable std::mutex mutex_;
    std::map<std::string, std::unique_ptr<TerminalSession>> sessions_;
    std::string currentId_;
    std::uint64_t nextId_ = 1;
    std::atomic<std::uint64_t> epoch_{0};

    OutputSink outputSink_;
    ErrorSink errorSink_;
    StateSink stateSink_;
    SessionListSink listSink_;
};

} // namespace lithe::windows::app
