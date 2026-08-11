#pragma once

#include <expected>
#include <optional>
#include <string>
#include <utility>

namespace lithe::windows {

enum class CoreErrorCode {
    InvalidRequest,
    WorkspaceNotFound,
    PermissionDenied,
    ExternalConflict,
    NotSupported,
    RuntimeMissing,
    ProcessStartFailed,
    ProcessFailed,
    ParseFailed,
    Cancelled,
    TimedOut,
    Unknown,
};

struct CoreError {
    CoreErrorCode code = CoreErrorCode::Unknown;
    std::string message;
    std::optional<std::string> details;
};

template <typename T>
using CoreResult = std::expected<T, CoreError>;

inline CoreError makeCoreError(CoreErrorCode code,
                               std::string message,
                               std::optional<std::string> details = std::nullopt) {
    return CoreError{code, std::move(message), std::move(details)};
}

} // namespace lithe::windows
