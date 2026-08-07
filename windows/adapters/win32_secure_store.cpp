#include "win32_secure_store.h"

#include <cstdint>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#endif

namespace lithe::windows {
namespace {

std::string storageKey(const std::string& key) {
    return "secure." + key;
}

#ifdef _WIN32
std::string winError(DWORD code = GetLastError()) {
    char* buffer = nullptr;
    const auto length = FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<LPSTR>(&buffer), 0, nullptr);
    std::string message = length > 0 && buffer != nullptr
        ? std::string(buffer, length)
        : "Win32 error " + std::to_string(code);
    if (buffer != nullptr) LocalFree(buffer);
    while (!message.empty() && (message.back() == '\r' || message.back() == '\n')) {
        message.pop_back();
    }
    return message;
}
#endif

} // namespace

Win32SecureStore::Win32SecureStore(std::filesystem::path root)
    : store_(std::move(root)) {}

std::optional<std::string> Win32SecureStore::read(const std::string& key) const {
    const auto value = store_.readValue(storageKey(key));
    if (!value || !std::holds_alternative<std::vector<std::uint8_t>>(*value)) {
        return std::nullopt;
    }
#ifdef _WIN32
    const auto& encrypted = std::get<std::vector<std::uint8_t>>(*value);
    DATA_BLOB input{static_cast<DWORD>(encrypted.size()),
                    const_cast<BYTE*>(reinterpret_cast<const BYTE*>(encrypted.data()))};
    DATA_BLOB output{};
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &output)) {
        return std::nullopt;
    }
    std::string result(reinterpret_cast<const char*>(output.pbData), output.cbData);
    LocalFree(output.pbData);
    return result;
#else
    return std::nullopt;
#endif
}

bool Win32SecureStore::write(const std::string& key,
                             const std::string& value,
                             std::string& error) {
#ifdef _WIN32
    DATA_BLOB input{static_cast<DWORD>(value.size()),
                    const_cast<BYTE*>(reinterpret_cast<const BYTE*>(value.data()))};
    DATA_BLOB output{};
    if (!CryptProtectData(&input, L"Lithe credential", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
        error = winError();
        return false;
    }
    std::vector<std::uint8_t> encrypted(output.pbData, output.pbData + output.cbData);
    LocalFree(output.pbData);
    return store_.writeValue(storageKey(key), std::move(encrypted), error);
#else
    error = "DPAPI is only available on Windows";
    (void)key;
    (void)value;
    return false;
#endif
}

bool Win32SecureStore::remove(const std::string& key, std::string& error) {
    return store_.remove(storageKey(key), error);
}

} // namespace lithe::windows
