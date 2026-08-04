#pragma once

#include "ports.h"

namespace lithe::windows {

class Win32RuntimeLocator final : public RuntimeLocator {
public:
    RuntimeDiscoveryResult discover() const override;
};

} // namespace lithe::windows
