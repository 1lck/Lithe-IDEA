#pragma once

#include "ports.h"

#include <memory>

namespace lithe::windows {

class Win32FileSystem final : public WorkspaceFileSystem {
public:
    FileReadResult readUtf8(const std::string& path) override;
    bool writeAtomic(const std::string& path,
                     const std::string& text,
                     std::string& error) override;
    bool move(const std::string& source,
              const std::string& destination,
              std::string& error) override;
    bool remove(const std::string& path, std::string& error) override;
};

} // namespace lithe::windows
