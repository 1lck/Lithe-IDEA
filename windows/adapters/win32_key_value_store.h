#pragma once

#include "ports.h"

#include <filesystem>

namespace lithe::windows {

class Win32KeyValueStore final : public KeyValueStore {
public:
    explicit Win32KeyValueStore(std::filesystem::path root = {});

    std::optional<std::string> read(const std::string& key) const override;
    bool write(const std::string& key,
               const std::string& value,
               std::string& error) override;
    bool remove(const std::string& key, std::string& error) override;

private:
    std::filesystem::path root_;
    std::filesystem::path pathForKey(const std::string& key) const;
};

} // namespace lithe::windows
