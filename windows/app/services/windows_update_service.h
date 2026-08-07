#pragma once

#include "ports.h"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::app {

struct WindowsReleaseAsset {
    std::string name;
    std::string downloadURL;
    std::uint64_t size = 0;
    std::optional<std::string> sha256;
};

struct WindowsRelease {
    std::string version;
    std::string tag;
    std::string pageURL;
    bool draft = false;
    bool prerelease = false;
    std::vector<WindowsReleaseAsset> assets;
};

enum class WindowsUpdateErrorCode {
    TransportFailure,
    HTTPFailure,
    InvalidResponse,
    NoPublishedRelease,
    NoCompatibleAsset,
    MissingChecksum,
    ChecksumMismatch,
    SignatureVerificationFailed,
    FileWriteFailed,
};

struct WindowsUpdateError {
    WindowsUpdateErrorCode code = WindowsUpdateErrorCode::InvalidResponse;
    std::string message;
    std::int32_t statusCode = 0;
};

class WindowsUpdateService final {
public:
    WindowsUpdateService(AIHTTPTransport& transport, FileStorage& storage);

    std::optional<WindowsRelease> checkLatest(const std::string& repository,
                                               const std::string& currentVersion,
                                               WindowsUpdateError& error) const;
    std::optional<WindowsReleaseAsset> selectAsset(const WindowsRelease& release,
                                                   std::string_view architecture,
                                                   WindowsUpdateError& error) const;
    bool downloadAndVerify(const WindowsReleaseAsset& asset,
                           const std::filesystem::path& destination,
                           WindowsUpdateError& error) const;

    static std::string sha256(std::string_view bytes);
    static std::optional<WindowsRelease> parseRelease(std::string_view body,
                                                       WindowsUpdateError& error);
    static std::optional<std::string> checksumForAsset(std::string_view checksumBody,
                                                       std::string_view assetName);

private:
    AIHTTPTransport& transport_;
    FileStorage& storage_;
};

} // namespace lithe::windows::app
