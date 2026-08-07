#pragma once

#include <filesystem>
#include <string>

namespace lithe::windows {

class Win32AuthenticodeVerifier final {
public:
    bool verify(const std::filesystem::path& file, std::string& error) const;
};

} // namespace lithe::windows
