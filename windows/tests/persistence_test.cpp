#include "app_persistence.h"

#include <cassert>
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
    MemoryStore store;
    lithe::windows::app::AppSettingsStore settingsStore(store);
    lithe::windows::app::AppSettings settings;
    settings.editorFontSize = 15.5;
    settings.showCodeVision = false;
    settings.terminalShellPath = "C:/Windows/System32/cmd.exe";
    settings.hiddenDirectoryNames = {"generated"};
    std::string error;
    assert(settingsStore.save(settings, error));
    const auto loadedSettings = settingsStore.load();
    assert(loadedSettings.editorFontSize == 15.5);
    assert(!loadedSettings.showCodeVision);
    assert(loadedSettings.terminalShellPath == settings.terminalShellPath);
    assert(loadedSettings.hiddenDirectoryNames == settings.hiddenDirectoryNames);

    lithe::windows::app::RecentProjectsStore recent(store, 2);
    assert(recent.record("one", error));
    assert(recent.record("two", error));
    assert(recent.record("one", error));
    assert(recent.load() == std::vector<std::string>({"one", "two"}));
    assert(recent.record("three", error));
    assert(recent.load() == std::vector<std::string>({"three", "one"}));

    lithe::windows::app::WorkspaceSessionStore sessions(store);
    const lithe::windows::app::WorkspaceSession session{
        {"src/Main.java", "README.md"}, {"src"}, "src/Main.java"};
    assert(sessions.save("C:/project", session, error));
    const auto loadedSession = sessions.load("C:/project");
    assert(loadedSession.openPaths == session.openPaths);
    assert(loadedSession.expandedPaths == session.expandedPaths);
    assert(loadedSession.activePath == session.activePath);
    assert(sessions.clear("C:/project", error));
    assert(sessions.load("C:/project").openPaths.empty());
    return 0;
}
