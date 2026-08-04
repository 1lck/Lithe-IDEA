#pragma once

#include "ports.h"

#include <memory>

namespace lithe::windows {

class Win32ProcessSession final : public ProcessSession {
public:
    Win32ProcessSession();
    ~Win32ProcessSession() override;

    void start(const ProcessRequest& request) override;
    void send(const std::string& input) override;
    void stop() override;
    bool isRunning() const override;
    void setOutputHandler(OutputHandler handler) override;
    void setLifecycleHandler(LifecycleHandler handler) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace lithe::windows
