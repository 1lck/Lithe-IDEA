#pragma once

#include "ports.h"

#include "win32_key_value_store.h"

#include <filesystem>

namespace lithe::windows {

class Win32SecureStore final : public SecureStore {
public:
    explicit Win32SecureStore(std::filesystem::path root = {});

    std::optional<std::string> read(const std::string& key) const override;
    bool write(const std::string& key,
               const std::string& value,
               std::string& error) override;
    bool remove(const std::string& key, std::string& error) override;

private:
    Win32KeyValueStore store_;
};

} // namespace lithe::windows
