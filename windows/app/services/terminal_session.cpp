#include "terminal_session.h"

#include <filesystem>
#include <utility>

namespace lithe::windows::app {

namespace {

std::string shellBasename(const std::string& executablePath) {
    try {
        const auto path = std::filesystem::path(executablePath);
        const auto leaf = path.filename().u8string();
        if (!leaf.empty()) {
            return {reinterpret_cast<const char*>(leaf.data()), leaf.size()};
        }
    } catch (...) {
        // Fall through to the manual split below if path parsing throws.
    }
    auto pos = executablePath.find_last_of("\\/");
    return pos == std::string::npos ? executablePath : executablePath.substr(pos + 1);
}

} // namespace

TerminalSession::TerminalSession(std::string id, std::unique_ptr<TerminalTransport> transport)
    : id_(std::move(id)), transport_(std::move(transport)) {
}

TerminalSession::~TerminalSession() {
    if (transport_) transport_->stop();
}

const std::string& TerminalSession::operationID() const noexcept {
    return operationID_;
}

TerminalSession::State TerminalSession::state() const noexcept {
    return state_;
}

std::optional<int> TerminalSession::exitCode() const noexcept {
    return exitCode_;
}

std::size_t TerminalSession::generation() const noexcept {
    return static_cast<std::size_t>(generation_);
}

std::string TerminalSession::render(std::size_t maxCharacters) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return buffer_.render(maxCharacters);
}

void TerminalSession::launch(const TerminalShellSpec& shell,
                             const std::string& workingDirectory,
                             const std::map<std::string, std::string>& environment,
                             std::string operationID) {
    ProcessRequest request;
    request.operationID = operationID;
    request.executablePath = shell.executablePath;
    request.arguments = shell.arguments;
    request.workingDirectory = workingDirectory.empty()
        ? std::optional<std::string>{} : std::optional<std::string>{workingDirectory};
    request.environment = environment;
    // An interactive shell must keep its stdin open for the lifetime of the
    // session; closing it would terminate the shell.
    request.keepsStandardInputOpen = true;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        shell_ = shell;
        workingDirectory_ = workingDirectory;
        environment_ = environment;
        operationID_ = std::move(operationID);
        ++generation_;
        state_ = State::Starting;
        exitCode_.reset();
        title_ = makeTitle(workingDirectory_, shell);
        bindTransportHandlers(generation_, operationID_);
    }

    transport_->start(request);
}

void TerminalSession::send(const std::string& input) {
    transport_->send(input);
}

void TerminalSession::interrupt() {
    // ETX (Ctrl+C) is the conventional interrupt byte for a pseudo-console.
    transport_->send(std::string{'\x03'});
}

void TerminalSession::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    buffer_.reset();
}

void TerminalSession::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == State::Finished || state_ == State::Failed) {
            // Already terminal; a duplicate stop must remain a no-op.
            return;
        }
        state_ = State::Stopping;
    }
    transport_->stop();
}

void TerminalSession::restart() {
    TerminalShellSpec shell;
    std::string workingDirectory;
    std::map<std::string, std::string> environment;
    std::string nextOperationID;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!shell_) {
            // Nothing to restart; never invent a shell spec.
            return;
        }
        shell = *shell_;
        workingDirectory = workingDirectory_;
        environment = environment_;
        nextOperationID = operationID_ + "-restart";
    }

    stop();
    launch(shell, workingDirectory, environment, std::move(nextOperationID));
}

void TerminalSession::setSinks(OutputSink output, ErrorSink error, StateSink state) {
    std::lock_guard<std::mutex> lock(mutex_);
    sinks_ = {std::move(output), std::move(error), std::move(state)};
}

void TerminalSession::bindTransportHandlers(std::uint64_t generation, std::string operationID) {
    // Captured by value: a restart re-binds with a fresh generation, so
    // callbacks tagged with the previous generation are dropped below.
    transport_->setOutputHandler(
        [this, generation](const std::string& bytes) { onOutput(generation, bytes); });
    transport_->setErrorHandler(
        [this, generation](const std::string& message) { onError(generation, message); });
    transport_->setExitHandler([this, generation]() { onExit(generation); });
    transport_->setLifecycleHandler(
        [this, generation, operationID](const ProcessLifecycleEvent& event) {
            onLifecycle(generation, operationID, event);
        });
}

void TerminalSession::onOutput(std::uint64_t generation, const std::string& bytes) {
    OutputSink sink;
    std::string id = id_;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation_ != generation) return; // stale launch
        buffer_.append(bytes);
        sink = sinks_.output;
    }
    if (sink) sink(id, bytes);
}

void TerminalSession::onError(std::uint64_t generation, const std::string& message) {
    ErrorSink sink;
    std::string id = id_;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation_ != generation) return;
        sink = sinks_.error;
    }
    if (sink) sink(id, message);
}

void TerminalSession::onExit(std::uint64_t generation) {
    // The lifecycle event is authoritative for exit; this no-arg hook only fires
    // for transports that did not emit a Finished lifecycle event.
    StateSink sink;
    std::string id = id_;
    State state = State::Finished;
    std::optional<int> exit;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation_ != generation) return;
        if (state_ == State::Finished) return;
        state_ = State::Finished;
        state = state_;
        exit = exitCode_;
        sink = sinks_.state;
    }
    if (sink) sink(id, state, exit);
}

void TerminalSession::onLifecycle(std::uint64_t generation,
                                  const std::string& operationID,
                                  const ProcessLifecycleEvent& event) {
    if (!event.operationID.empty() && event.operationID != operationID) return;
    State next = State::Finished;
    switch (event.state) {
        case ProcessLifecycleState::Starting: next = State::Starting; break;
        case ProcessLifecycleState::Running: next = State::Running; break;
        case ProcessLifecycleState::Stopping: next = State::Stopping; break;
        case ProcessLifecycleState::Finished: next = State::Finished; break;
        case ProcessLifecycleState::Failed: next = State::Failed; break;
    }
    std::optional<int> exit = event.exitCode ? std::optional<int>{*event.exitCode} : std::nullopt;
    StateSink sink;
    std::string id = id_;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation_ != generation) return; // stale launch
        state_ = next;
        if (exit.has_value()) exitCode_ = exit;
        sink = sinks_.state;
    }
    if (sink) sink(id, next, exit);
}

std::string TerminalSession::makeTitle(const std::string& workingDirectory,
                                       const TerminalShellSpec& shell) {
    const auto shellName = shellBasename(shell.executablePath);
    if (workingDirectory.empty()) return shellName;
    try {
        const auto leaf = std::filesystem::path(workingDirectory).filename().u8string();
        if (!leaf.empty()) {
            return shellName + " — " + std::string(reinterpret_cast<const char*>(leaf.data()), leaf.size());
        }
    } catch (...) {
        // Ignore; fall back to the full working directory.
    }
    return shellName + " — " + workingDirectory;
}

} // namespace lithe::windows::app
