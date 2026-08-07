#include "core_client.h"

#include <atomic>
#include <utility>

extern "C" {
const char* lithe_core_version(void);
char* lithe_core_execute_json(const char* request);
std::int32_t lithe_core_cancel(const char* operationID);
void lithe_core_free_string(char* value);
}

namespace lithe::windows {

namespace {

std::string escapeJson(std::string value) {
    std::string escaped;
    escaped.reserve(value.size() + 8);
    for (const char character : value) {
        switch (character) {
        case '\\': escaped += "\\\\"; break;
        case '"': escaped += "\\\""; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default: escaped += character; break;
        }
    }
    return escaped;
}

} // namespace

CoreCall CoreClient::makeCall(std::optional<std::uint64_t> timeoutMilliseconds) {
    const auto requestID = "windows-" + std::to_string(
        nextRequestID_.fetch_add(1, std::memory_order_relaxed) + 1);
    return CoreCall{requestID, requestID, timeoutMilliseconds};
}

CoreResult<CoreResponse> CoreClient::execute(const CoreCall& call,
                                             const std::string& command,
                                             const std::string& payloadJson) {
    if (!call.isValid()) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::InvalidRequest, "Core call is missing an id or operation id"));
    }
    const auto payload = payloadJson.empty() ? "{}" : payloadJson;
    auto request = "{\"id\":\"" + escapeJson(call.id)
        + "\",\"operationId\":\"" + escapeJson(call.operationID)
        + "\",\"command\":\"" + escapeJson(command)
        + "\",\"payload\":" + payload + "}";
    if (call.timeoutMilliseconds.has_value()) {
        request.insert(request.size() - 1,
                       ",\"timeoutMilliseconds\":"
                           + std::to_string(*call.timeoutMilliseconds));
    }
    return executeRaw(request);
}

CoreResult<CoreResponse> CoreClient::execute(
    const std::string& command,
    const std::string& payloadJson,
    std::optional<std::uint64_t> timeoutMilliseconds) {
    return execute(makeCall(timeoutMilliseconds), command, payloadJson);
}

CoreResult<CoreResponse> CoreClient::executeRaw(const std::string& requestJson) {
    char* response = lithe_core_execute_json(requestJson.c_str());
    if (response == nullptr) {
        return std::unexpected(makeCoreError(
            CoreErrorCode::Unknown, "Rust core returned a null response"));
    }
    std::string json(response);
    lithe_core_free_string(response);
    return CoreResponse{std::move(json)};
}

bool CoreClient::cancel(const std::string& operationID) const {
    return lithe_core_cancel(operationID.c_str()) != 0;
}

bool CoreClient::cancel(const CoreCall& call) const {
    return call.isValid() && cancel(call.operationID);
}

std::string CoreClient::version() const {
    const auto* value = lithe_core_version();
    return value == nullptr ? std::string{} : std::string(value);
}

} // namespace lithe::windows
