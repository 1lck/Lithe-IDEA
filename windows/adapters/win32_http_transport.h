#pragma once

#include "ports.h"

namespace lithe::windows {

class Win32HttpTransport final : public AIHTTPTransport {
public:
    std::optional<HTTPResponse> send(const HTTPRequest& request,
                                     std::string& error) override;
};

} // namespace lithe::windows
