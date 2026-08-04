#pragma once

#include "ports.h"

namespace lithe::windows {

class Win32ProcessRunner final : public ProcessRunner {
public:
    ProcessResult run(const ProcessRequest& request) override;
};

} // namespace lithe::windows
