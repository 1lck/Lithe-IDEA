#pragma once

#include "ports.h"
#include "terminal_buffer.h"

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lithe::windows::app {

// Shell command line used to start a terminal session.
struct TerminalShellSpec {
    std::string executablePath;
    std::vector<std::string> arguments;
};

// A single terminal session. Owns its ConPTY transport and a bounded output
// buffer, tracks lifecycle state, and drops callbacks that belong to a previous
// launch (so a restart's late output/exit never reaches the UI). Pure
// application logic: depends only on the TerminalTransport port and the
// TerminalBuffer algorithm, never on Qt or Win32 types.
class TerminalSession {
public:
    using State = ProcessLifecycleState;

    using OutputSink = std::function<void(const std::string& sessionId, const std::string& bytes)>;
    using ErrorSink = std::function<void(const std::string& sessionId, const std::string& error)>;
    using StateSink = std::function<void(const std::string& sessionId,
                                         State state,
                                         const std::optional<int>& exitCode)>;

    TerminalSession(std::string id, std::unique_ptr<TerminalTransport> transport);
    ~TerminalSession();

    TerminalSession(const TerminalSession&) = delete;
    TerminalSession& operator=(const TerminalSession&) = delete;
    TerminalSession(TerminalSession&&) = delete;
    TerminalSession& operator=(TerminalSession&&) = delete;

    const std::string& id() const noexcept { return id_; }
    const std::string& title() const noexcept { return title_; }
    State state() const noexcept;
    std::optional<int> exitCode() const noexcept;
    const std::string& workingDirectory() const noexcept { return workingDirectory_; }
    const std::string& operationID() const noexcept;
    std::size_t generation() const noexcept;

    // Snapshot of the bounded buffer for rendering. The argument caps the
    // returned string length so the UI never copies an unbounded payload.
    std::string render(std::size_t maxCharacters) const;

    // Starts the shell. The operationID identifies this launch on the wire so
    // lifecycle/output callbacks tagged with a different id can be dropped.
    void launch(const TerminalShellSpec& shell,
                const std::string& workingDirectory,
                const std::map<std::string, std::string>& environment,
                std::string operationID);

    void send(const std::string& input);
    // Sends the standard interrupt byte (Ctrl+C) to the shell's input.
    void interrupt();
    // Resets the visible buffer only; the shell keeps running.
    void clear();
    void stop();
    // Stops the current launch and relaunches the same shell in the same
    // working directory under a fresh operationID. Late callbacks from the
    // previous launch are dropped via the generation check.
    void restart();

    void setSinks(OutputSink output, ErrorSink error, StateSink state);

private:
    struct Callbacks {
        OutputSink output;
        ErrorSink error;
        StateSink state;
    };

    std::string id_;
    std::string title_;
    std::unique_ptr<TerminalTransport> transport_;
    algorithms::TerminalBuffer buffer_;

    mutable std::mutex mutex_;
    std::string workingDirectory_;
    std::map<std::string, std::string> environment_;
    std::optional<TerminalShellSpec> shell_;
    std::string operationID_;
    std::uint64_t generation_ = 0;
    State state_ = State::Finished;
    std::optional<int> exitCode_;
    Callbacks sinks_;

    void bindTransportHandlers(std::uint64_t generation, std::string operationID);
    void onOutput(std::uint64_t generation, const std::string& bytes);
    void onError(std::uint64_t generation, const std::string& message);
    void onExit(std::uint64_t generation);
    void onLifecycle(std::uint64_t generation,
                     const std::string& operationID,
                     const ProcessLifecycleEvent& event);
    static std::string makeTitle(const std::string& workingDirectory, const TerminalShellSpec& shell);
};

} // namespace lithe::windows::app
