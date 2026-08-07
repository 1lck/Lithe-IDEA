#include "windows_update_service.h"

#include "json_value.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <system_error>

namespace lithe::windows::app {
namespace {

const JsonValue* value(const JsonValue& object, std::string_view key) {
    return objectValue(object, key);
}

std::string stringValue(const JsonValue* value) {
    return value && value->asString() ? *value->asString() : std::string{};
}

bool boolValue(const JsonValue* value) {
    return value && value->asBool() ? *value->asBool() : false;
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](char character) {
        return static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    });
    return value;
}

std::string trim(std::string value) {
    const auto space = [](unsigned char character) { return std::isspace(character) != 0; };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), [&](char character) {
        return !space(static_cast<unsigned char>(character));
    }));
    value.erase(std::find_if(value.rbegin(), value.rend(), [&](char character) {
        return !space(static_cast<unsigned char>(character));
    }).base(), value.end());
    return value;
}

std::vector<int> versionParts(std::string value) {
    value = trim(std::move(value));
    if (!value.empty() && value.front() == 'v') value.erase(0, 1);
    if (const auto dash = value.find('-'); dash != std::string::npos) value.erase(dash);
    std::vector<int> parts;
    std::size_t start = 0;
    while (start < value.size()) {
        const auto end = value.find('.', start);
        const auto part = value.substr(start, end == std::string::npos
                                                ? std::string::npos : end - start);
        if (part.empty() || !std::all_of(part.begin(), part.end(), [](char character) {
                return std::isdigit(static_cast<unsigned char>(character)) != 0;
            })) return {};
        int number = 0;
        const auto parsed = std::from_chars(part.data(), part.data() + part.size(), number);
        if (parsed.ec != std::errc{} || parsed.ptr != part.data() + part.size()) return {};
        parts.push_back(number);
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return parts;
}

bool newerVersion(std::string candidate, std::string current) {
    const auto candidateParts = versionParts(std::move(candidate));
    const auto currentParts = versionParts(std::move(current));
    if (candidateParts.empty() || currentParts.empty()) return false;
    const auto count = std::max(candidateParts.size(), currentParts.size());
    for (std::size_t index = 0; index < count; ++index) {
        const auto candidateValue = index < candidateParts.size() ? candidateParts[index] : 0;
        const auto currentValue = index < currentParts.size() ? currentParts[index] : 0;
        if (candidateValue != currentValue) return candidateValue > currentValue;
    }
    return false;
}

void setError(WindowsUpdateError& error, WindowsUpdateErrorCode code,
              std::string message, std::int32_t status = 0) {
    error.code = code;
    error.message = std::move(message);
    error.statusCode = status;
}

std::string pathText(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char*>(value.data()), value.size()};
}

constexpr std::array<std::uint32_t, 64> SHA256_K = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
    0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
    0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
    0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

std::uint32_t rotateRight(std::uint32_t value, std::uint32_t count) {
    return (value >> count) | (value << (32 - count));
}

} // namespace

WindowsUpdateService::WindowsUpdateService(AIHTTPTransport& transport, FileStorage& storage)
    : transport_(transport), storage_(storage) {}

std::optional<WindowsRelease> WindowsUpdateService::checkLatest(
    const std::string& repository, const std::string& currentVersion,
    WindowsUpdateError& error) const {
    if (repository.empty() || repository.find('/') == std::string::npos) {
        setError(error, WindowsUpdateErrorCode::InvalidResponse, "GitHub repository is invalid.");
        return std::nullopt;
    }
    HTTPRequest request;
    request.method = "GET";
    request.url = "https://api.github.com/repos/" + repository + "/releases/latest";
    request.headers = {{"Accept", "application/vnd.github+json"},
                       {"User-Agent", "Lithe-Windows-Updater"}};
    request.timeoutMilliseconds = 30000;
    std::string transportError;
    const auto response = transport_.send(request, transportError);
    if (!response) {
        setError(error, WindowsUpdateErrorCode::TransportFailure,
                 transportError.empty() ? "Could not query GitHub releases." : transportError);
        return std::nullopt;
    }
    if (response->statusCode < 200 || response->statusCode >= 300) {
        setError(error, WindowsUpdateErrorCode::HTTPFailure,
                 "GitHub returned HTTP " + std::to_string(response->statusCode) + ".",
                 response->statusCode);
        return std::nullopt;
    }
    auto release = parseRelease(response->body, error);
    if (!release) return std::nullopt;
    if (release->draft || release->prerelease || !newerVersion(release->version, currentVersion)) {
        setError(error, WindowsUpdateErrorCode::NoPublishedRelease,
                 "No newer published Windows release is available.");
        return std::nullopt;
    }
    return release;
}

std::optional<WindowsRelease> WindowsUpdateService::parseRelease(
    std::string_view body, WindowsUpdateError& error) {
    const auto parsed = parseJson(body);
    if (!parsed.value || !parsed.value->isObject()) {
        setError(error, WindowsUpdateErrorCode::InvalidResponse,
                 "GitHub returned invalid release JSON.");
        return std::nullopt;
    }
    WindowsRelease release;
    release.tag = stringValue(value(*parsed.value, "tag_name"));
    release.version = release.tag;
    if (!release.version.empty() && release.version.front() == 'v') release.version.erase(0, 1);
    release.pageURL = stringValue(value(*parsed.value, "html_url"));
    release.draft = boolValue(value(*parsed.value, "draft"));
    release.prerelease = boolValue(value(*parsed.value, "prerelease"));
    const auto* assets = value(*parsed.value, "assets");
    if (release.tag.empty() || !assets || !assets->asArray()) {
        setError(error, WindowsUpdateErrorCode::InvalidResponse,
                 "GitHub release is missing tag or assets.");
        return std::nullopt;
    }
    for (const auto& item : *assets->asArray()) {
        const auto name = stringValue(value(item, "name"));
        const auto url = stringValue(value(item, "browser_download_url"));
        if (name.empty() || url.empty()) continue;
        release.assets.push_back({name, url,
            value(item, "size") && value(item, "size")->asUInt()
                ? *value(item, "size")->asUInt() : 0, std::nullopt});
    }
    if (release.assets.empty()) {
        setError(error, WindowsUpdateErrorCode::NoPublishedRelease,
                 "The GitHub release has no downloadable assets.");
        return std::nullopt;
    }
    return release;
}

std::optional<WindowsReleaseAsset> WindowsUpdateService::selectAsset(
    const WindowsRelease& release, std::string_view architecture,
    WindowsUpdateError& error) const {
    const auto wanted = lower(std::string(architecture));
    auto candidate = std::find_if(release.assets.begin(), release.assets.end(), [&](const auto& asset) {
        const auto name = lower(asset.name);
        const bool installer = name.ends_with(".msi") || name.ends_with(".exe");
        const bool windows = name.find("win") != std::string::npos ||
                             name.find("windows") != std::string::npos;
        const bool arch = wanted.empty() || name.find(wanted) != std::string::npos ||
                          (wanted == "x64" && (name.find("amd64") != std::string::npos ||
                                                name.find("win64") != std::string::npos));
        return installer && windows && arch;
    });
    if (candidate == release.assets.end()) {
        setError(error, WindowsUpdateErrorCode::NoCompatibleAsset,
                 "No compatible Windows installer was found in the release.");
        return std::nullopt;
    }
    auto result = *candidate;
    auto checksumAsset = std::find_if(release.assets.begin(), release.assets.end(), [](const auto& asset) {
        const auto name = lower(asset.name);
        return name.find("sha256") != std::string::npos || name.ends_with(".sha") ||
               name.find("checksum") != std::string::npos;
    });
    if (checksumAsset == release.assets.end()) {
        setError(error, WindowsUpdateErrorCode::MissingChecksum,
                 "The release does not publish a checksum file.");
        return std::nullopt;
    }
    HTTPRequest request;
    request.method = "GET";
    request.url = checksumAsset->downloadURL;
    request.headers = {{"Accept", "text/plain"}, {"User-Agent", "Lithe-Windows-Updater"}};
    request.timeoutMilliseconds = 30000;
    std::string transportError;
    const auto response = transport_.send(request, transportError);
    if (!response) {
        setError(error, WindowsUpdateErrorCode::TransportFailure,
                 transportError.empty() ? "Could not download the release checksum." : transportError);
        return std::nullopt;
    }
    if (response->statusCode < 200 || response->statusCode >= 300) {
        setError(error, WindowsUpdateErrorCode::HTTPFailure,
                 "The checksum download returned HTTP " + std::to_string(response->statusCode) + ".",
                 response->statusCode);
        return std::nullopt;
    }
    result.sha256 = checksumForAsset(response->body, result.name);
    if (!result.sha256) {
        setError(error, WindowsUpdateErrorCode::MissingChecksum,
                 "The release checksum file has no entry for the selected installer.");
        return std::nullopt;
    }
    return result;
}

std::optional<std::string> WindowsUpdateService::checksumForAsset(
    std::string_view checksumBody, std::string_view assetName) {
    const auto isDigest = [](std::string_view value) {
        return value.size() == 64 && std::all_of(value.begin(), value.end(), [](char character) {
            return std::isxdigit(static_cast<unsigned char>(character)) != 0;
        });
    };
    std::size_t start = 0;
    while (start <= checksumBody.size()) {
        const auto end = checksumBody.find('\n', start);
        auto line = trim(std::string(checksumBody.substr(start,
            end == std::string_view::npos ? checksumBody.size() - start : end - start)));
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const auto separator = line.find_first_of(" \t");
        if (separator != std::string::npos) {
            const auto digest = lower(line.substr(0, separator));
            auto file = trim(line.substr(separator));
            if (!file.empty() && file.front() == '*') file.erase(0, 1);
            if (isDigest(digest) && file == assetName) return digest;
        }

        // BSD shasum uses: SHA256 (asset-name) = digest.
        constexpr std::string_view bsdPrefix = "SHA256 (";
        if (line.starts_with(bsdPrefix)) {
            const auto close = line.find(") = ", bsdPrefix.size());
            if (close != std::string::npos &&
                std::string_view(line).substr(bsdPrefix.size(), close - bsdPrefix.size()) == assetName) {
                const auto digest = lower(trim(line.substr(close + 4)));
                if (isDigest(digest)) return digest;
            }
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return std::nullopt;
}

bool WindowsUpdateService::downloadAndVerify(const WindowsReleaseAsset& asset,
                                              const std::filesystem::path& destination,
                                              WindowsUpdateError& error) const {
    if (!asset.sha256) {
        setError(error, WindowsUpdateErrorCode::MissingChecksum,
                 "The installer has no checksum.");
        return false;
    }
    HTTPRequest request;
    request.method = "GET";
    request.url = asset.downloadURL;
    request.headers = {{"User-Agent", "Lithe-Windows-Updater"}};
    request.timeoutMilliseconds = 120000;
    std::string transportError;
    const auto response = transport_.send(request, transportError);
    if (!response) {
        setError(error, WindowsUpdateErrorCode::TransportFailure,
                 transportError.empty() ? "Could not download the installer." : transportError);
        return false;
    }
    if (response->statusCode < 200 || response->statusCode >= 300) {
        setError(error, WindowsUpdateErrorCode::HTTPFailure,
                 "The installer download returned HTTP " + std::to_string(response->statusCode) + ".",
                 response->statusCode);
        return false;
    }
    if (lower(sha256(response->body)) != lower(trim(*asset.sha256))) {
        setError(error, WindowsUpdateErrorCode::ChecksumMismatch,
                 "The installer checksum does not match the published checksum.");
        return false;
    }
    std::string writeError;
    const std::vector<std::uint8_t> bytes(response->body.begin(), response->body.end());
    if (!storage_.writeData(pathText(destination), bytes, writeError)) {
        setError(error, WindowsUpdateErrorCode::FileWriteFailed,
                 writeError.empty() ? "Could not write the downloaded installer." : writeError);
        return false;
    }
    return true;
}

std::string WindowsUpdateService::sha256(std::string_view bytes) {
    std::vector<std::uint8_t> message(bytes.begin(), bytes.end());
    const auto bitLength = static_cast<std::uint64_t>(message.size()) * 8;
    message.push_back(0x80);
    while ((message.size() % 64) != 56) message.push_back(0);
    for (int shift = 56; shift >= 0; shift -= 8) {
        message.push_back(static_cast<std::uint8_t>((bitLength >> shift) & 0xff));
    }
    std::array<std::uint32_t, 8> hash = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    for (std::size_t offset = 0; offset < message.size(); offset += 64) {
        std::array<std::uint32_t, 64> words{};
        for (std::size_t index = 0; index < 16; ++index) {
            const auto position = offset + index * 4;
            words[index] = (static_cast<std::uint32_t>(message[position]) << 24) |
                (static_cast<std::uint32_t>(message[position + 1]) << 16) |
                (static_cast<std::uint32_t>(message[position + 2]) << 8) |
                static_cast<std::uint32_t>(message[position + 3]);
        }
        for (std::size_t index = 16; index < 64; ++index) {
            const auto s0 = rotateRight(words[index - 15], 7) ^ rotateRight(words[index - 15], 18) ^
                            (words[index - 15] >> 3);
            const auto s1 = rotateRight(words[index - 2], 17) ^ rotateRight(words[index - 2], 19) ^
                            (words[index - 2] >> 10);
            words[index] = words[index - 16] + s0 + words[index - 7] + s1;
        }
        auto [a, b, c, d, e, f, g, h] = hash;
        for (std::size_t index = 0; index < 64; ++index) {
            const auto s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
            const auto choice = (e & f) ^ ((~e) & g);
            const auto temp1 = h + s1 + choice + SHA256_K[index] + words[index];
            const auto s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
            const auto majority = (a & b) ^ (a & c) ^ (b & c);
            const auto temp2 = s0 + majority;
            h = g; g = f; f = e; e = d + temp1; d = c; c = b; b = a; a = temp1 + temp2;
        }
        hash[0] += a; hash[1] += b; hash[2] += c; hash[3] += d;
        hash[4] += e; hash[5] += f; hash[6] += g; hash[7] += h;
    }
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (const auto value : hash) output << std::setw(8) << value;
    return output.str();
}

} // namespace lithe::windows::app
