#pragma once

#include "ports.h"

#include <filesystem>

namespace lithe::windows {

class Win32FileStorage final : public FileStorage {
public:
    std::string homeDirectory() const override;
    std::string cacheDirectory() const override;
    std::string applicationSupportDirectory() const override;
    std::optional<FileMetadata> metadata(const std::string& path) const override;
    bool fileExists(const std::string& path) const override;
    bool isExecutable(const std::string& path) const override;
    std::vector<std::string> listDirectory(const std::string& path) const override;
    std::optional<std::vector<std::uint8_t>> readData(
        const std::string& path, std::string& error) const override;
    bool writeData(const std::string& path,
                   const std::vector<std::uint8_t>& data,
                   std::string& error) override;
    bool createDirectory(const std::string& path,
                         bool withIntermediateDirectories,
                         std::string& error) override;
    bool removeItem(const std::string& path, std::string& error) override;
    bool moveItem(const std::string& source,
                  const std::string& destination,
                  std::string& error) override;
};

} // namespace lithe::windows
