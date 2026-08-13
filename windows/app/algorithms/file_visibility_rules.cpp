#include "file_visibility_rules.h"

#include <algorithm>
#include <cctype>
#include <optional>

namespace lithe::windows::algorithms {
namespace {

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::string slashNormalize(std::string value) {
    std::replace(value.begin(), value.end(), '\\', '/');
    const bool absolute = !value.empty() && value.front() == '/';
    const bool driveAbsolute = value.size() >= 3 &&
        std::isalpha(static_cast<unsigned char>(value[0])) && value[1] == ':' &&
        value[2] == '/';
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto end = value.find('/', start);
        const auto partEnd = end == std::string::npos ? value.size() : end;
        const auto part = value.substr(start, partEnd - start);
        if (part.empty() || part == ".") {
            // Skip separators and current-directory components.
        } else if (part == ".." && !parts.empty() && parts.back() != ".." &&
                   !(parts.size() == 1 && parts.front().size() == 2 && parts.front()[1] == ':')) {
            parts.pop_back();
        } else if (part != ".." || (!absolute && !driveAbsolute)) {
            parts.push_back(part);
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    std::string result;
    if (absolute) result = "/";
    for (std::size_t index = 0; index < parts.size(); ++index) {
        if (!result.empty() && result.back() != '/') result += '/';
        result += parts[index];
    }
    if (result.empty() && (absolute || driveAbsolute)) return driveAbsolute ? value.substr(0, 3) : "/";
    while (result.size() > 1 && result.back() == '/') result.pop_back();
    return result;
}

std::vector<std::string> components(std::string_view value) {
    std::vector<std::string> result;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto end = value.find('/', start);
        const auto partEnd = end == std::string_view::npos ? value.size() : end;
        if (partEnd > start && value.substr(start, partEnd - start) != ".") {
            result.emplace_back(value.substr(start, partEnd - start));
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return result;
}

} // namespace

const std::vector<std::string>& FileVisibilityRules::builtInHiddenDirectories() {
    static const std::vector<std::string> values{
        ".git", ".worktree", ".worktrees", ".build", ".swiftpm",
        "node_modules", "target", "build",
        "DerivedData", ".gradle", ".next", "dist", "coverage",
        "design-qa-artifacts"};
    return values;
}

const std::vector<std::string>& FileVisibilityRules::builtInHiddenFilePatterns() {
    static const std::vector<std::string> values{".DS_Store"};
    return values;
}

FileVisibilityRules::FileVisibilityRules(std::vector<std::string> hiddenDirectoryNames,
                                         std::vector<std::string> hiddenFilePatterns) {
    auto addUnique = [](std::vector<std::string>& target, std::string value) {
        value = normalizeEntry(value);
        if (value.empty()) return;
        const auto normalized = lower(value);
        const auto found = std::find_if(target.begin(), target.end(), [&](const auto& item) {
            return lower(item) == normalized;
        });
        if (found == target.end()) target.push_back(std::move(value));
    };
    for (const auto& value : builtInHiddenDirectories()) addUnique(hiddenDirectoryNames_, value);
    for (const auto& value : hiddenDirectoryNames) addUnique(hiddenDirectoryNames_, value);
    for (const auto& value : builtInHiddenFilePatterns()) addUnique(hiddenFilePatterns_, value);
    for (const auto& value : hiddenFilePatterns) addUnique(hiddenFilePatterns_, value);
}

bool FileVisibilityRules::isHidden(std::string_view path,
                                   std::string_view root,
                                   bool isDirectoryKnown,
                                   bool isDirectory) const {
    auto normalizedPath = slashNormalize(std::string(path));
    auto normalizedRoot = slashNormalize(std::string(root));
    std::string relative;
    if (normalizedPath == normalizedRoot) return false;
    const auto prefix = normalizedRoot.empty() ? std::string{} : normalizedRoot + "/";
    if (!prefix.empty() && normalizedPath.rfind(prefix, 0) == 0) {
        relative = normalizedPath.substr(prefix.size());
    } else {
        const auto slash = normalizedPath.rfind('/');
        relative = slash == std::string::npos ? normalizedPath : normalizedPath.substr(slash + 1);
    }
    if (relative.empty()) return false;
    const auto parts = components(relative);
    if (parts.empty()) return false;
    const auto& last = parts.back();
    const auto directoryCount = isDirectoryKnown && isDirectory
        ? parts.size()
        : parts.size() - (isDirectoryKnown && !isDirectory ? 1 : 0);
    for (std::size_t index = 0; index < directoryCount; ++index) {
        if (isHiddenDirectoryName(parts[index])) return true;
    }
    if (isDirectoryKnown && isDirectory && isHiddenDirectoryName(last)) return true;
    if (isDirectoryKnown && isDirectory) return false;
    return std::any_of(hiddenFilePatterns_.begin(), hiddenFilePatterns_.end(), [&](const auto& pattern) {
        return globMatches(pattern, last) || globMatches(pattern, relative);
    });
}

bool FileVisibilityRules::isHiddenDirectoryName(std::string_view name) const {
    const auto normalized = lower(std::string(name));
    return std::any_of(hiddenDirectoryNames_.begin(), hiddenDirectoryNames_.end(),
                       [&](const auto& value) { return lower(value) == normalized; });
}

std::string FileVisibilityRules::normalizeEntry(std::string_view value) {
    std::size_t start = 0;
    std::size_t end = value.size();
    while (start < end && std::isspace(static_cast<unsigned char>(value[start]))) ++start;
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) --end;
    return std::string(value.substr(start, end - start));
}

bool FileVisibilityRules::globMatches(std::string_view pattern, std::string_view value) {
    const auto patternCharacters = lower(std::string(pattern));
    const auto valueCharacters = lower(std::string(value));
    std::size_t patternIndex = 0;
    std::size_t valueIndex = 0;
    std::optional<std::size_t> starIndex;
    std::size_t starMatchIndex = 0;
    while (valueIndex < valueCharacters.size()) {
        if (patternIndex < patternCharacters.size()) {
            const auto character = patternCharacters[patternIndex];
            if (character == valueCharacters[valueIndex] || character == '?') {
                ++patternIndex;
                ++valueIndex;
                continue;
            }
        }
        if (patternIndex < patternCharacters.size() && patternCharacters[patternIndex] == '*') {
            starIndex = patternIndex++;
            starMatchIndex = valueIndex;
        } else if (starIndex) {
            patternIndex = *starIndex + 1;
            valueIndex = ++starMatchIndex;
        } else {
            return false;
        }
    }
    while (patternIndex < patternCharacters.size() && patternCharacters[patternIndex] == '*') {
        ++patternIndex;
    }
    return patternIndex == patternCharacters.size();
}

} // namespace lithe::windows::algorithms
