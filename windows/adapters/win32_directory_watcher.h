#pragma once

#include "ports.h"

#include <memory>

namespace lithe::windows {

class Win32DirectoryChangeSource final : public DirectoryChangeSource {
public:
    Win32DirectoryChangeSource();
    ~Win32DirectoryChangeSource() override;

    void start(const std::string& root,
               ChangeHandler handler,
               ErrorHandler errorHandler = {}) override;
    void stop() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    void stopImpl();
};

} // namespace lithe::windows
