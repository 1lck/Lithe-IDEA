#include "app_persistence.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <variant>

namespace lithe::windows::app {
namespace {

constexpr std::string_view kSystemUiLanguage = "system";
constexpr std::string_view kEnglishUiLanguage = "en";
constexpr std::string_view kSimplifiedChineseUiLanguage = "zh_CN";

template <typename T>
std::optional<T> read(const KeyValueStore& store, const char* key) {
    const auto value = store.readValue(key);
    if (!value || !std::holds_alternative<T>(*value)) return std::nullopt;
    return std::get<T>(*value);
}

bool write(KeyValueStore& store, const char* key, KeyValueValue value, std::string& error) {
    return store.writeValue(key, value, error);
}

std::vector<std::string> encodeDocumentViews(
    const std::vector<WorkspaceSession::DocumentView>& views) {
    std::vector<std::string> encoded;
    encoded.reserve(views.size());
    for (const auto& view : views) {
        encoded.push_back(view.path + "|" + std::to_string(view.cursor) + "|" +
            std::to_string(view.anchor) + "|" + std::to_string(view.verticalScroll) + "|" +
            std::to_string(view.horizontalScroll));
    }
    return encoded;
}

std::vector<WorkspaceSession::DocumentView> decodeDocumentViews(
    const std::vector<std::string>& encoded) {
    std::vector<WorkspaceSession::DocumentView> views;
    for (const auto& value : encoded) {
        std::array<std::string_view, 5> fields;
        std::size_t start = 0;
        bool valid = true;
        for (std::size_t index = 0; index < fields.size(); ++index) {
            const auto separator = value.find('|', start);
            const auto end = separator == std::string::npos ? value.size() : separator;
            fields[index] = std::string_view(value).substr(start, end - start);
            if (index + 1 < fields.size() && separator == std::string::npos) valid = false;
            start = end + 1;
        }
        if (!valid || fields[0].empty()) continue;
        WorkspaceSession::DocumentView view;
        view.path = fields[0];
        auto parse = [](std::string_view field, std::uint64_t& output) {
            const auto [end, error] = std::from_chars(
                field.data(), field.data() + field.size(), output);
            return error == std::errc{} && end == field.data() + field.size();
        };
        if (!parse(fields[1], view.cursor) || !parse(fields[2], view.anchor) ||
            !parse(fields[3], view.verticalScroll) ||
            !parse(fields[4], view.horizontalScroll)) continue;
        views.push_back(std::move(view));
    }
    return views;
}

} // namespace

std::string normalizeUiLanguage(std::string_view configuredLanguage) {
    if (configuredLanguage == kEnglishUiLanguage) return std::string(kEnglishUiLanguage);
    if (configuredLanguage == kSimplifiedChineseUiLanguage) {
        return std::string(kSimplifiedChineseUiLanguage);
    }
    return std::string(kSystemUiLanguage);
}

std::string effectiveUiLanguage(std::string_view configuredLanguage,
                                bool systemLocaleIsChinese) {
    const auto normalized = normalizeUiLanguage(configuredLanguage);
    if (normalized != kSystemUiLanguage) return normalized;
    return std::string(systemLocaleIsChinese ? kSimplifiedChineseUiLanguage
                                             : kEnglishUiLanguage);
}

std::string normalizeDataDirectory(std::string_view configuredDirectory) {
    std::string value(configuredDirectory);
    const auto isSpace = [](unsigned char character) {
        return std::isspace(character) != 0;
    };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(),
        [&](char character) { return !isSpace(static_cast<unsigned char>(character)); }));
    value.erase(std::find_if(value.rbegin(), value.rend(),
        [&](char character) { return !isSpace(static_cast<unsigned char>(character)); }).base(),
        value.end());
    for (auto& character : value) {
        if (character == '\\') character = '/';
    }
    while (!value.empty() && value.back() == '/') value.pop_back();
    return value;
}


AppSettingsStore::AppSettingsStore(KeyValueStore& store) : store_(store) {}

AppSettings AppSettingsStore::load() const {
    AppSettings result;
    if (const auto value = read<double>(store_, "lithe.settings.editorFontSize")) {
        result.editorFontSize = *value;
    }
    if (const auto value = read<bool>(store_, "lithe.settings.showCodeVision")) {
        result.showCodeVision = *value;
    }
    if (const auto value = read<bool>(store_, "lithe.settings.showInlayHints")) {
        result.showInlayHints = *value;
    }
    if (const auto value = read<std::string>(store_, "lithe.settings.uiLanguage")) {
        result.uiLanguage = normalizeUiLanguage(*value);
    }
    if (const auto value = read<std::string>(store_, "lithe.settings.dataDirectory")) {
        result.dataDirectory = normalizeDataDirectory(*value);
    }
    if (const auto value = read<std::string>(store_, "lithe.settings.terminalShellPath")) {
        result.terminalShellPath = *value;
    }
    if (const auto value = read<std::vector<std::string>>(store_, "lithe.settings.hiddenDirectoryNames")) {
        result.hiddenDirectoryNames = *value;
    }
    if (const auto value = read<std::vector<std::string>>(store_, "lithe.settings.hiddenFilePatterns")) {
        result.hiddenFilePatterns = *value;
    }
    return result;
}

bool AppSettingsStore::save(const AppSettings& settings, std::string& error) {
    if (!write(store_, "lithe.settings.editorFontSize", settings.editorFontSize, error)) return false;
    if (!write(store_, "lithe.settings.showCodeVision", settings.showCodeVision, error)) return false;
    if (!write(store_, "lithe.settings.showInlayHints", settings.showInlayHints, error)) return false;
    if (!write(store_, "lithe.settings.uiLanguage",
               normalizeUiLanguage(settings.uiLanguage), error)) return false;
    if (!write(store_, "lithe.settings.dataDirectory",
               normalizeDataDirectory(settings.dataDirectory), error)) return false;
    if (!write(store_, "lithe.settings.terminalShellPath", settings.terminalShellPath, error)) return false;
    if (!write(store_, "lithe.settings.hiddenDirectoryNames", settings.hiddenDirectoryNames, error)) return false;
    return write(store_, "lithe.settings.hiddenFilePatterns", settings.hiddenFilePatterns, error);
}

RecentProjectsStore::RecentProjectsStore(KeyValueStore& store, std::size_t maximum)
    : store_(store), maximum_(std::max<std::size_t>(1, maximum)) {}

std::vector<std::string> RecentProjectsStore::load() const {
    return read<std::vector<std::string>>(store_, "lithe.recentProjects").value_or(std::vector<std::string>{});
}

bool RecentProjectsStore::record(const std::string& path, std::string& error) {
    if (path.empty()) return true;
    auto paths = load();
    paths.erase(std::remove(paths.begin(), paths.end(), path), paths.end());
    paths.insert(paths.begin(), path);
    if (paths.size() > maximum_) paths.resize(maximum_);
    return replace(std::move(paths), error);
}

bool RecentProjectsStore::replace(std::vector<std::string> paths, std::string& error) {
    std::vector<std::string> unique;
    unique.reserve(std::min(maximum_, paths.size()));
    for (auto& path : paths) {
        if (path.empty() || std::find(unique.begin(), unique.end(), path) != unique.end()) continue;
        unique.push_back(std::move(path));
        if (unique.size() == maximum_) break;
    }
    return write(store_, "lithe.recentProjects", std::move(unique), error);
}

WorkspaceSessionStore::WorkspaceSessionStore(KeyValueStore& store) : store_(store) {}

std::string WorkspaceSessionStore::key(const std::string& root, const char* field) {
    return "lithe.session." + root + "." + field;
}

WorkspaceSession WorkspaceSessionStore::load(const std::string& workspaceRoot) const {
    WorkspaceSession result;
    if (const auto value = read<std::vector<std::string>>(
            store_, key(workspaceRoot, "openPaths").c_str())) result.openPaths = *value;
    if (const auto value = read<std::vector<std::string>>(
            store_, key(workspaceRoot, "expandedPaths").c_str())) result.expandedPaths = *value;
    if (const auto value = read<std::string>(store_, key(workspaceRoot, "activePath").c_str())) {
        result.activePath = *value;
    }
    if (const auto value = read<std::vector<std::string>>(
            store_, key(workspaceRoot, "documentViews").c_str())) {
        result.documentViews = decodeDocumentViews(*value);
    }
    return result;
}

bool WorkspaceSessionStore::save(const std::string& workspaceRoot,
                                 const WorkspaceSession& session,
                                 std::string& error) {
    if (!write(store_, key(workspaceRoot, "openPaths").c_str(), session.openPaths, error)) return false;
    if (!write(store_, key(workspaceRoot, "expandedPaths").c_str(), session.expandedPaths, error)) return false;
    if (!write(store_, key(workspaceRoot, "activePath").c_str(), session.activePath, error)) return false;
    return write(store_, key(workspaceRoot, "documentViews").c_str(),
                 encodeDocumentViews(session.documentViews), error);
}

bool WorkspaceSessionStore::clear(const std::string& workspaceRoot, std::string& error) {
    const auto fields = {"openPaths", "expandedPaths", "activePath", "documentViews"};
    for (const auto* field : fields) {
        const auto value = store_.readValue(key(workspaceRoot, field));
        if (!value) continue;
        if (!store_.remove(key(workspaceRoot, field), error)) return false;
    }
    return true;
}

} // namespace lithe::windows::app
