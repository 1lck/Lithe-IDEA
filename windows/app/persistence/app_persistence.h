#pragma once

#include "ports.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lithe::windows::app {

std::string normalizeUiLanguage(std::string_view configuredLanguage);
std::string effectiveUiLanguage(std::string_view configuredLanguage,
                                bool systemLocaleIsChinese);
std::string normalizeDataDirectory(std::string_view configuredDirectory);

struct AppSettings {
    double editorFontSize = 13.0;
    bool showCodeVision = true;
    bool showInlayHints = true;
    std::string uiLanguage = "system";
    std::string dataDirectory;
    std::string terminalShellPath;
    std::vector<std::string> hiddenDirectoryNames;
    std::vector<std::string> hiddenFilePatterns;
};

class AppSettingsStore final {
public:
    explicit AppSettingsStore(KeyValueStore& store);

    AppSettings load() const;
    bool save(const AppSettings& settings, std::string& error);

private:
    KeyValueStore& store_;
};

class RecentProjectsStore final {
public:
    explicit RecentProjectsStore(KeyValueStore& store, std::size_t maximum = 20);

    std::vector<std::string> load() const;
    bool record(const std::string& path, std::string& error);
    bool replace(std::vector<std::string> paths, std::string& error);

private:
    KeyValueStore& store_;
    std::size_t maximum_;
};

struct WorkspaceSession {
    struct DocumentView {
        std::string path;
        std::uint64_t cursor = 0;
        std::uint64_t anchor = 0;
        std::uint64_t verticalScroll = 0;
        std::uint64_t horizontalScroll = 0;
    };

    std::vector<std::string> openPaths;
    std::vector<std::string> expandedPaths;
    std::string activePath;
    std::vector<DocumentView> documentViews;
};

class WorkspaceSessionStore final {
public:
    explicit WorkspaceSessionStore(KeyValueStore& store);

    WorkspaceSession load(const std::string& workspaceRoot) const;
    bool save(const std::string& workspaceRoot,
              const WorkspaceSession& session,
              std::string& error);
    bool clear(const std::string& workspaceRoot, std::string& error);

private:
    KeyValueStore& store_;

    static std::string key(const std::string& root, const char* field);
};

} // namespace lithe::windows::app
