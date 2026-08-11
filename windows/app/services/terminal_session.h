#pragma once

#include "ports.h"
#include "terminal_emulator.h"

#include <atomic>
#include <chrono>
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

// A single terminal session. Owns its ConPTY transport and the terminal
// emulator, tracks lifecycle state, and drops callbacks that belong to a
// previous launch (so a restart's late output/exit never reaches the UI). Pure
// application logic: depends only on the TerminalTransport port and the
// TerminalEmulator algorithm, never on Qt or Win32 types.
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

    // Display metadata for the terminal chrome (status bar / tab titles). All
    // derived from session state — no shell cooperation needed.
    std::chrono::system_clock::time_point startedAt() const;
    std::chrono::system_clock::time_point endedAt() const;
    // Whole elapsed seconds between startedAt and endedAt (or now if still
    // running), clamped at zero; 0 before the first launch.
    long long elapsedSeconds(std::chrono::system_clock::time_point now) const;
    // "MM:SS", or "H:MM:SS" past one hour. Empty before the first launch.
    std::string elapsedDescription(std::chrono::system_clock::time_point now) const;
    // The process (OSC) title if one is set, otherwise empty. No OSC channel
    // exists yet, so this stays empty until title reporting lands.
    const std::string& processTitle() const noexcept;
    // The process title if set, otherwise the shell's base name.
    std::string displayName() const;
    // Last path component of the working directory ("" if none).
    std::string directoryName() const;

    // Plain-text snapshot of the emulator grid for rendering. The argument caps
    // the returned string length so the UI never copies an unbounded payload.
    std::string render(std::size_t maxCharacters) const;

    // The emulator backing this session. Read access is thread-safe (the
    // emulator synchronizes itself); the surface widget draws from it.
    const algorithms::TerminalEmulator& emulator() const noexcept;

    // Starts the shell. The operationID identifies this launch on the wire so
    // lifecycle/output callbacks tagged with a different id can be dropped.
    void launch(const TerminalShellSpec& shell,
                const std::string& workingDirectory,
                const std::map<std::string, std::string>& environment,
                std::string operationID);

    void send(const std::string& input);
    // Sends the standard interrupt byte (Ctrl+C) to the shell's input.
    void interrupt();
    // Resizes the emulator grid and forwards the new geometry to the transport
    // so the shell's window is resized to match.
    void resize(int columns, int rows);
    // Scrolls the emulator's scrollback viewport (offset 0 is the live bottom).
    void setScrollOffset(int offset) { emulator_.setScrollOffset(offset); }
    void scrollBy(int deltaLines) { emulator_.scrollBy(deltaLines); }
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
    algorithms::TerminalEmulator emulator_;

    mutable std::mutex mutex_;
    std::string workingDirectory_;
    std::map<std::string, std::string> environment_;
    std::optional<TerminalShellSpec> shell_;
    std::string operationID_;
    std::uint64_t generation_ = 0;
    // Written by the transport worker thread (under mutex_) and read by the UI
    // / test thread via state() without the lock — atomic so that cross-thread
    // read is defined behaviour and the Running transition is observable.
    std::atomic<State> state_{State::Finished};
    std::optional<int> exitCode_;
    std::chrono::system_clock::time_point startedAt_{};
    std::chrono::system_clock::time_point endedAt_{};
    std::string processTitle_;
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
