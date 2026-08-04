#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace lithe::windows {

struct CoreResponse {
    std::string json;

    bool isValid() const noexcept { return !json.empty(); }
};

// Thin ownership-safe wrapper around the shared Rust C ABI. Qt code can parse
// the returned UTF-8 JSON with QJsonDocument without depending on Swift.
class CoreClient final {
public:
    CoreClient() = default;

    CoreResponse execute(const std::string& command,
                         const std::string& payloadJson = "{}",
                         std::optional<std::uint32_t> timeoutMilliseconds = std::nullopt);
    CoreResponse executeRaw(const std::string& requestJson);
    bool cancel(const std::string& operationID) const;
    std::string version() const;

private:
    std::uint64_t nextRequestID_ = 0;
};

} // namespace lithe::windows
