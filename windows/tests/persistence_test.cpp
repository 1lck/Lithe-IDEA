#include "app_persistence.h"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>

class MemoryStore final : public lithe::windows::KeyValueStore {
public:
    std::optional<lithe::windows::KeyValueValue> readValue(const std::string& key) const override {
        const auto found = values.find(key);
        return found == values.end() ? std::nullopt : std::optional(found->second);
    }

    bool writeValue(const std::string& key,
                    const lithe::windows::KeyValueValue& value,
                    std::string&) override {
        values[key] = value;
        return true;
    }

    bool remove(const std::string& key, std::string&) override {
        values.erase(key);
        return true;
    }

private:
    std::map<std::string, lithe::windows::KeyValueValue> values;
};

int main() {
    using lithe::windows::app::effectiveUiLanguage;
    using lithe::windows::app::normalizeUiLanguage;
    assert(normalizeUiLanguage("") == "system");
    assert(normalizeUiLanguage("system") == "system");
    assert(normalizeUiLanguage("en") == "en");
    assert(normalizeUiLanguage("zh_CN") == "zh_CN");
    assert(normalizeUiLanguage("zh-CN") == "system");
    assert(effectiveUiLanguage("system", true) == "zh_CN");
    assert(effectiveUiLanguage("system", false) == "en");
    assert(effectiveUiLanguage("en", true) == "en");
    assert(effectiveUiLanguage("zh_CN", false) == "zh_CN");
    using lithe::windows::app::normalizeDataDirectory;
assert(normalizeDataDirectory("") == "");
assert(normalizeDataDirectory("  ") == "");
assert(normalizeDataDirectory("E:\\LitheData\\") == "E:/LitheData");
assert(normalizeDataDirectory("E:/LitheData/") == "E:/LitheData");
assert(normalizeDataDirectory("E:/LitheData") == "E:/LitheData");
assert(normalizeDataDirectory("D:\\LitheData") == "D:/LitheData");
assert(normalizeDataDirectory("D:/Lithe/Data/") == "D:/Lithe/Data");

    MemoryStore store;
    lithe::windows::app::AppSettingsStore settingsStore(store);
    lithe::windows::app::AppSettings settings;
    settings.editorFontSize = 15.5;
    settings.showCodeVision = false;
    settings.uiLanguage = "zh_CN";
    settings.dataDirectory = "E:\\LitheData\\";
    settings.terminalShellPath = "C:/Windows/System32/cmd.exe";
    settings.hiddenDirectoryNames = {"generated"};
    std::string error;
    assert(settingsStore.save(settings, error));
    const auto loadedSettings = settingsStore.load();
    assert(loadedSettings.editorFontSize == 15.5);
    assert(!loadedSettings.showCodeVision);
    assert(loadedSettings.uiLanguage == "zh_CN");
    assert(loadedSettings.dataDirectory == "E:/LitheData");
    assert(loadedSettings.terminalShellPath == settings.terminalShellPath);
    assert(loadedSettings.hiddenDirectoryNames == settings.hiddenDirectoryNames);

    settings.uiLanguage = "zh-CN";
    assert(settingsStore.save(settings, error));
    assert(settingsStore.load().uiLanguage == "system");

    lithe::windows::app::RecentProjectsStore recent(store, 2);
    assert(recent.record("one", error));
    assert(recent.record("two", error));
    assert(recent.record("one", error));
    assert(recent.load() == std::vector<std::string>({"one", "two"}));
    assert(recent.record("three", error));
    assert(recent.load() == std::vector<std::string>({"three", "one"}));
    assert(recent.replace({"one"}, error));
    assert(recent.load() == std::vector<std::string>({"one"}));

    lithe::windows::app::WorkspaceSessionStore sessions(store);
    const lithe::windows::app::WorkspaceSession session{
        {"src/Main.java", "README.md"}, {"src"}, "src/Main.java", "shelf-123"};
    assert(sessions.save("C:/project", session, error));
    const auto loadedSession = sessions.load("C:/project");
    assert(loadedSession.openPaths == session.openPaths);
    assert(loadedSession.expandedPaths == session.expandedPaths);
    assert(loadedSession.activePath == session.activePath);
    assert(loadedSession.deferredShelfId == session.deferredShelfId);
    assert(sessions.load("D:/other-project").openPaths.empty());
    assert(sessions.clear("C:/project", error));
    assert(sessions.load("C:/project").openPaths.empty());

    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto root = std::filesystem::temp_directory_path() /
        ("lithe-session-test-" + std::to_string(nonce));
    const auto outside = std::filesystem::temp_directory_path() /
        ("lithe-session-outside-" + std::to_string(nonce));
    std::filesystem::create_directories(root / "src");
    std::filesystem::create_directories(outside);
    std::ofstream(root / "src" / "Main.java") << "class Main {}\n";
    std::ofstream(root / "README.md") << "readme\n";
    std::ofstream(outside / "secret.txt") << "outside\n";
    std::error_code symlinkError;
    std::filesystem::create_directory_symlink(outside, root / "escaped", symlinkError);

    lithe::windows::app::WorkspaceSession unsafeSession{
        {
            "src\\Main.java",
            "src/Main.java",
            "README.md",
            "missing.txt",
            "src",
            "../outside.txt",
            "C:/outside.txt",
            "escaped/secret.txt",
        },
        {"", "src", "src", "README.md", "missing", "../outside"},
        "missing.txt",
        "shelf-recovery",
    };
    const auto sanitized = lithe::windows::app::sanitizeWorkspaceSession(
        root, std::move(unsafeSession));
    assert(sanitized.openPaths ==
           (std::vector<std::string>{"src/Main.java", "README.md"}));
    assert(sanitized.expandedPaths ==
           (std::vector<std::string>{"", "src"}));
    assert(sanitized.activePath.empty());
    assert(sanitized.deferredShelfId == "shelf-recovery");

    auto activeSession = sanitized;
    activeSession.activePath = "src\\Main.java";
    const auto withActive = lithe::windows::app::sanitizeWorkspaceSession(
        root, std::move(activeSession));
    assert(withActive.activePath == "src/Main.java");

    std::filesystem::remove_all(root);
    std::filesystem::remove_all(outside);
    return 0;
}
