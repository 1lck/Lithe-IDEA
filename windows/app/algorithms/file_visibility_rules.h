#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::algorithms {

class FileVisibilityRules final {
public:
    static const std::vector<std::string>& builtInHiddenDirectories();
    static const std::vector<std::string>& builtInHiddenFilePatterns();

    FileVisibilityRules(std::vector<std::string> hiddenDirectoryNames = {},
                        std::vector<std::string> hiddenFilePatterns = {});

    bool isHidden(std::string_view path,
                  std::string_view root,
                  bool isDirectoryKnown = false,
                  bool isDirectory = false) const;
    bool isHiddenDirectoryName(std::string_view name) const;

private:
    std::vector<std::string> hiddenDirectoryNames_;
    std::vector<std::string> hiddenFilePatterns_;

    static std::string normalizeEntry(std::string_view value);
    static bool globMatches(std::string_view pattern, std::string_view value);
};

} // namespace lithe::windows::algorithms
