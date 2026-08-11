#pragma once

#include "ports.h"

#include <string>
#include <vector>

namespace lithe::windows::tests {

// A drop-in TerminalTransport for platform-independent feature/Qt tests. It
// records inputs, stores the handlers the session/model bind on it, and exposes
// helpers to drive scripted output, lifecycle, exit, and error callbacks
// deterministically from the test thread. Mirrors the FakeProcess pattern used
// for ProcessSession tests.
class FakeTerminalTransport final : public TerminalTransport {
public:
    ProcessRequest request;
    std::vector<std::string> sends;
    int resizeColumns = 0;
    int resizeRows = 0;
    int startCallCount = 0;
    int stopCallCount = 0;
    OutputHandler output;
    ErrorHandler error;
    ExitHandler exit;
    LifecycleHandler lifecycle;
    bool running = false;

    void start(const ProcessRequest& value) override {
        request = value;
        ++startCallCount;
        running = true;
    }
    void send(const std::string& input) override { sends.push_back(input); }
    void stop() override {
        ++stopCallCount;
        running = false;
    }
    bool isRunning() const override { return running; }
    void resize(int columns, int rows) override {
        resizeColumns = columns;
        resizeRows = rows;
    }
    void setOutputHandler(OutputHandler handler) override { output = std::move(handler); }
    void setErrorHandler(ErrorHandler handler) override { error = std::move(handler); }
    void setExitHandler(ExitHandler handler) override { exit = std::move(handler); }
    void setLifecycleHandler(LifecycleHandler handler) override { lifecycle = std::move(handler); }

    // --- test driving helpers ---
    void feed(const std::string& bytes) { if (output) output(bytes); }
    void emitError(const std::string& message) { if (error) error(message); }
    void emitExit() { if (exit) exit(); }
    void emitState(ProcessLifecycleState state,
                   const std::optional<std::int32_t>& exitCode = std::nullopt,
                   const std::string& operationID = {}) {
        if (lifecycle) {
            ProcessLifecycleEvent event;
            event.operationID = operationID.empty() ? request.operationID : operationID;
            event.state = state;
            event.exitCode = exitCode;
            lifecycle(event);
        }
    }
};

} // namespace lithe::windows::tests
