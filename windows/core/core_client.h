#pragma once

#include "core_error.h"

#include <cstdint>
#include <atomic>
#include <optional>
#include <string>

namespace lithe::windows {

struct CoreResponse {
    std::string json;

    bool isValid() const noexcept { return !json.empty(); }
};

struct CoreCall {
    std::string id;
    std::string operationID;
    std::optional<std::uint64_t> timeoutMilliseconds;

    bool isValid() const noexcept {
        return !id.empty() && !operationID.empty();
    }
};

// Thin ownership-safe wrapper around the shared Rust C ABI. Qt code can parse
// the returned UTF-8 JSON with QJsonDocument without depending on Swift.
class CoreClient final {
public:
    CoreClient() = default;

    CoreCall makeCall(std::optional<std::uint64_t> timeoutMilliseconds = std::nullopt);

    CoreResult<CoreResponse> execute(const CoreCall& call,
                                     const std::string& command,
                                     const std::string& payloadJson = "{}");

    CoreResult<CoreResponse> execute(
        const std::string& command,
        const std::string& payloadJson = "{}",
        std::optional<std::uint64_t> timeoutMilliseconds = std::nullopt);
    CoreResult<CoreResponse> executeRaw(const std::string& requestJson);
    bool cancel(const CoreCall& call) const;
    bool cancel(const std::string& operationID) const;
    std::string version() const;

private:
    std::atomic<std::uint64_t> nextRequestID_{0};
};

} // namespace lithe::windows
