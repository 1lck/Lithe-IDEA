#pragma once

#include "ports.h"

#include <memory>

namespace lithe::windows {

class Win32TerminalTransport final : public TerminalTransport {
public:
    Win32TerminalTransport();
    ~Win32TerminalTransport() override;

    void start(const ProcessRequest& request) override;
    void send(const std::string& input) override;
    void stop() override;
    void resize(int columns, int rows) override;
    void setOutputHandler(OutputHandler handler) override;
    void setExitHandler(ExitHandler handler) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace lithe::windows
