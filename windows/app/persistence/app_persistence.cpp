#include "app_persistence.h"

#include <algorithm>
#include <variant>

namespace lithe::windows::app {
namespace {

template <typename T>
std::optional<T> read(const KeyValueStore& store, const char* key) {
    const auto value = store.readValue(key);
    if (!value || !std::holds_alternative<T>(*value)) return std::nullopt;
    return std::get<T>(*value);
}

bool write(KeyValueStore& store, const char* key, KeyValueValue value, std::string& error) {
    return store.writeValue(key, value, error);
}

} // namespace

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
    return result;
}

bool WorkspaceSessionStore::save(const std::string& workspaceRoot,
                                 const WorkspaceSession& session,
                                 std::string& error) {
    if (!write(store_, key(workspaceRoot, "openPaths").c_str(), session.openPaths, error)) return false;
    if (!write(store_, key(workspaceRoot, "expandedPaths").c_str(), session.expandedPaths, error)) return false;
    return write(store_, key(workspaceRoot, "activePath").c_str(), session.activePath, error);
}

bool WorkspaceSessionStore::clear(const std::string& workspaceRoot, std::string& error) {
    const auto fields = {"openPaths", "expandedPaths", "activePath"};
    for (const auto* field : fields) {
        const auto value = store_.readValue(key(workspaceRoot, field));
        if (!value) continue;
        if (!store_.remove(key(workspaceRoot, field), error)) return false;
    }
    return true;
}

} // namespace lithe::windows::app
