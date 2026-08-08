#include "workbench_layout_persistence.h"

#include <cassert>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <variant>

namespace {

using lithe::windows::KeyValueStore;
using lithe::windows::KeyValueValue;

class MemoryStore final : public KeyValueStore {
public:
    std::optional<KeyValueValue> readValue(const std::string& key) const override {
        ++readCount;
        const auto found = values.find(key);
        return found == values.end() ? std::nullopt : std::optional(found->second);
    }

    bool writeValue(const std::string& key,
                    const KeyValueValue& value,
                    std::string& error) override {
        ++writeCount;
        if (key == failKey) {
            error = "in-memory save failure";
            return false;
        }
        values[key] = value;
        return true;
    }

    bool remove(const std::string& key, std::string&) override {
        values.erase(key);
        return true;
    }

    mutable int readCount = 0;
    int writeCount = 0;
    std::string failKey;
    std::map<std::string, KeyValueValue> values;
};

std::string key(const std::string& root, const char* field) {
    return "lithe.ui.workbench." + root + "." + field;
}

void assertStateEquals(const lithe::windows::WorkbenchLayoutState& actual,
                       const lithe::windows::WorkbenchLayoutState& expected) {
    assert(actual.sidebarWidth == expected.sidebarWidth);
    assert(actual.editorTopHeight == expected.editorTopHeight);
    assert(actual.sidebarDestination == expected.sidebarDestination);
    assert(actual.bottomToolKind == expected.bottomToolKind);
    assert(actual.bottomVisible == expected.bottomVisible);
}

void roundTripPreservesAllFields() {
    MemoryStore store;
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    const lithe::windows::WorkbenchLayoutState expected{
        .sidebarWidth = 497,
        .editorTopHeight = 613,
        .sidebarDestination = lithe::windows::SidebarDestination::Git,
        .bottomToolKind = lithe::windows::BottomToolKind::Problems,
        .bottomVisible = false,
    };
    std::string error;

    assert(persistence.save("workspace-a", expected, error));
    assert(error.empty());
    assertStateEquals(persistence.load("workspace-a"), expected);
}

void workspaceRootsAreIsolated() {
    MemoryStore store;
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    const lithe::windows::WorkbenchLayoutState first{
        .sidebarWidth = 230,
        .editorTopHeight = 300,
        .sidebarDestination = lithe::windows::SidebarDestination::Search,
        .bottomToolKind = lithe::windows::BottomToolKind::Build,
        .bottomVisible = true,
    };
    const lithe::windows::WorkbenchLayoutState second{
        .sidebarWidth = 510,
        .editorTopHeight = 700,
        .sidebarDestination = lithe::windows::SidebarDestination::Project,
        .bottomToolKind = lithe::windows::BottomToolKind::Terminal,
        .bottomVisible = false,
    };
    std::string error;

    assert(persistence.save("workspace-a", first, error));
    assert(persistence.save("workspace-b", second, error));
    assertStateEquals(persistence.load("workspace-a"), first);
    assertStateEquals(persistence.load("workspace-b"), second);
}

void missingValuesUseDefaults() {
    MemoryStore store;
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    const lithe::windows::WorkbenchLayoutState saved{
        .sidebarWidth = 319,
        .editorTopHeight = 521,
        .sidebarDestination = lithe::windows::SidebarDestination::Search,
        .bottomToolKind = lithe::windows::BottomToolKind::Build,
        .bottomVisible = false,
    };
    std::string error;
    assert(persistence.save("workspace-a", saved, error));
    store.values.erase(key("workspace-a", "editorTopHeight"));
    store.values.erase(key("workspace-a", "sidebarDestination"));
    store.values.erase(key("workspace-a", "bottomToolKind"));
    store.values.erase(key("workspace-a", "bottomVisible"));

    const auto loaded = persistence.load("workspace-a");
    assert(loaded.sidebarWidth == 319);
    assert(loaded.editorTopHeight == 400);
    assert(loaded.sidebarDestination == lithe::windows::SidebarDestination::Project);
    assert(loaded.bottomToolKind == lithe::windows::BottomToolKind::Terminal);
    assert(loaded.bottomVisible);
}

void wrongTypesUseDefaults() {
    MemoryStore store;
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    store.values[key("workspace-a", "sidebarWidth")] = std::string("497");
    store.values[key("workspace-a", "editorTopHeight")] = true;
    store.values[key("workspace-a", "sidebarDestination")] = 1.0;
    store.values[key("workspace-a", "bottomToolKind")] = std::string("Build");
    store.values[key("workspace-a", "bottomVisible")] = std::int64_t{1};

    assertStateEquals(persistence.load("workspace-a"), {});
}

void invalidEnumsBecomeSafeAfterNormalization() {
    MemoryStore store;
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    store.values[key("workspace-a", "sidebarDestination")] = std::int64_t{99};
    store.values[key("workspace-a", "bottomToolKind")] = std::int64_t{-3};

    const auto normalized = lithe::windows::normalizeWorkbenchLayout(
        persistence.load("workspace-a"), 1200, 900);
    assert(normalized.sidebarDestination == lithe::windows::SidebarDestination::Project);
    assert(normalized.bottomToolKind == lithe::windows::BottomToolKind::Terminal);
    assert(normalized.sidebarWidth == 280);
    assert(normalized.editorTopHeight == 400);
    assert(normalized.bottomVisible);
}

void emptyWorkspaceRootDoesNotReadOrWrite() {
    MemoryStore store;
    store.values["lithe.ui.workbench..sidebarWidth"] = std::int64_t{999};
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    std::string error;

    const auto loaded = persistence.load("");
    assertStateEquals(loaded, {});
    assert(store.readCount == 0);
    assert(!persistence.save("", {}, error));
    assert(error == "workspace root is empty");
    assert(store.writeCount == 0);
}

void saveFailurePropagatesError() {
    MemoryStore store;
    lithe::windows::WorkbenchLayoutPersistence persistence(store);
    store.failKey = key("workspace-a", "editorTopHeight");
    std::string error;

    assert(!persistence.save("workspace-a", {}, error));
    assert(error == "in-memory save failure");
}

}

int main() {
    roundTripPreservesAllFields();
    workspaceRootsAreIsolated();
    missingValuesUseDefaults();
    wrongTypesUseDefaults();
    invalidEnumsBecomeSafeAfterNormalization();
    emptyWorkspaceRootDoesNotReadOrWrite();
    saveFailurePropagatesError();
    return 0;
}
