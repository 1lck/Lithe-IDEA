#include "workspace_paths.h"

#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <string_view>

namespace lithe::windows::app {
namespace {

std::string replaceSeparators(std::string value) {
    std::replace(value.begin(), value.end(), '\\', '/');
    while (value.size() > 1 && value.back() == '/') value.pop_back();
    return value;
}

} // namespace

std::optional<RelativePath> RelativePath::parse(std::string_view value) {
    if (value.empty() || value.front() == '/' || value.find('\0') != std::string_view::npos) {
        return std::nullopt;
    }
    std::string normalized(value);
    std::replace(normalized.begin(), normalized.end(), '\\', '/');
    if (normalized.front() == '/' || normalized.find(':') != std::string::npos) return std::nullopt;
    std::size_t start = 0;
    while (start <= normalized.size()) {
        const auto end = normalized.find('/', start);
        const auto partEnd = end == std::string::npos ? normalized.size() : end;
        const auto part = normalized.substr(start, partEnd - start);
        if (part.empty() || part == "." || part == "..") return std::nullopt;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return RelativePath(std::move(normalized));
}

std::optional<GitRef> GitRef::parse(std::string_view value) {
    if (value.empty() || value.front() == '-' || value.find('\\') != std::string_view::npos ||
        value.find('\0') != std::string_view::npos) return std::nullopt;
    return GitRef(std::string(value));
}

WorkspacePaths::WorkspacePaths(std::filesystem::path root)
    : root_(normalize(std::move(root))) {
    if (root_.empty()) throw std::invalid_argument("Workspace root must not be empty");
    if (!root_.is_absolute()) {
        root_ = normalize(std::filesystem::absolute(root_));
    }
}

std::filesystem::path WorkspacePaths::normalize(const std::filesystem::path& path) {
    return path.lexically_normal();
}

std::string WorkspacePaths::genericUtf8(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return std::string(reinterpret_cast<const char*>(value.data()), value.size());
}

std::string WorkspacePaths::comparisonKey(std::string value) {
    value = replaceSeparators(std::move(value));
#ifdef _WIN32
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
#endif
    return value;
}

bool WorkspacePaths::contains(const std::filesystem::path& path) const {
    if (!path.is_absolute()) return false;
    const auto rootKey = comparisonKey(genericUtf8(root_));
    const auto pathKey = comparisonKey(genericUtf8(normalize(path)));
    if (pathKey == rootKey) return true;
    if (rootKey.empty()) return false;
    const auto prefix = rootKey.back() == '/' ? rootKey : rootKey + '/';
    return pathKey.rfind(prefix, 0) == 0;
}

std::optional<std::string> WorkspacePaths::toRelative(
    const std::filesystem::path& path) const {
    if (!path.is_absolute()) return std::nullopt;
    const auto normalized = normalize(path);
    if (!contains(normalized)) return std::nullopt;

    const auto rootValue = replaceSeparators(genericUtf8(root_));
    const auto pathValue = replaceSeparators(genericUtf8(normalized));
    if (comparisonKey(pathValue) == comparisonKey(rootValue)) return std::string{};
    const auto prefix = rootValue.back() == '/' ? rootValue : rootValue + '/';
    // The containment check above used a platform-aware comparison key.  Use
    // the original spelling for the returned contract path.
    return pathValue.substr(prefix.size());
}

std::filesystem::path WorkspacePaths::toAbsolute(std::string_view relative) const {
    const auto parsed = RelativePath::parse(relative);
    if (!parsed) throw std::invalid_argument("Workspace path is not a valid relative path");
    const auto absolute = normalize(root_ / std::filesystem::path(parsed->value()));
    if (!contains(absolute)) {
        throw std::invalid_argument("Workspace path escapes workspace root");
    }
    return absolute;
}

} // namespace lithe::windows::app
