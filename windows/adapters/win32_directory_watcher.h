#pragma once

#include "ports.h"

#include <memory>

namespace lithe::windows {

class Win32DirectoryChangeSource final : public DirectoryChangeSource {
public:
    Win32DirectoryChangeSource();
    ~Win32DirectoryChangeSource() override;

    void start(const std::string& root, ChangeHandler handler) override;
    void stop() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace lithe::windows
