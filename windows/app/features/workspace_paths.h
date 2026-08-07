#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace lithe::windows::app {

class RelativePath final {
public:
    static std::optional<RelativePath> parse(std::string_view value);

    const std::string& value() const noexcept { return value_; }

private:
    explicit RelativePath(std::string value) : value_(std::move(value)) {}
    std::string value_;
};

class GitRef final {
public:
    static std::optional<GitRef> parse(std::string_view value);

    const std::string& value() const noexcept { return value_; }

private:
    explicit GitRef(std::string value) : value_(std::move(value)) {}
    std::string value_;
};

// The only conversion point between native filesystem paths and the slash-
// separated paths used by the Rust contract.  It is lexical by design: the
// macOS app uses standardizedFileURL semantics here and does not resolve
// symlinks for workspace identity.
class WorkspacePaths final {
public:
    explicit WorkspacePaths(std::filesystem::path root);

    const std::filesystem::path& root() const noexcept { return root_; }

    bool contains(const std::filesystem::path& path) const;

    // Returns a `/`-separated path relative to root, or nullopt when the
    // absolute path is outside the workspace.
    std::optional<std::string> toRelative(const std::filesystem::path& path) const;

    // Converts a contract-relative path back to the native path.  Invalid
    // absolute paths and paths escaping the workspace throw std::invalid_argument.
    std::filesystem::path toAbsolute(std::string_view relative) const;

private:
    std::filesystem::path root_;

    static std::filesystem::path normalize(const std::filesystem::path& path);
    static std::string genericUtf8(const std::filesystem::path& path);
    static std::string comparisonKey(std::string value);
};

} // namespace lithe::windows::app
