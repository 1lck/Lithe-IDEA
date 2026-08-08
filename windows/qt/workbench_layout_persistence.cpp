#include "workbench_layout_persistence.h"

#include <cstdint>
#include <limits>
#include <optional>
#include <variant>

namespace lithe::windows {
namespace {

template <typename T>
std::optional<T> readTypedValue(const KeyValueStore& store,
                                const std::string& key) {
    const auto value = store.readValue(key);
    if (!value || !std::holds_alternative<T>(*value)) return std::nullopt;
    return std::get<T>(*value);
}

int readIntValue(const KeyValueStore& store,
                 const std::string& key,
                 int fallback) {
    const auto value = readTypedValue<std::int64_t>(store, key);
    if (!value || *value < std::numeric_limits<int>::min() ||
        *value > std::numeric_limits<int>::max()) {
        return fallback;
    }
    return static_cast<int>(*value);
}

bool writeValue(KeyValueStore& store,
                const std::string& key,
                KeyValueValue value,
                std::string& error) {
    return store.writeValue(key, value, error);
}

}

WorkbenchLayoutPersistence::WorkbenchLayoutPersistence(KeyValueStore& store)
    : store_(store) {}

std::string WorkbenchLayoutPersistence::key(const std::string& workspaceRoot,
                                            const char* field) {
    return "lithe.ui.workbench." + workspaceRoot + "." + field;
}

WorkbenchLayoutState WorkbenchLayoutPersistence::load(
    const std::string& workspaceRoot) const {
    WorkbenchLayoutState result;
    if (workspaceRoot.empty()) return result;

    result.sidebarWidth = readIntValue(
        store_, key(workspaceRoot, "sidebarWidth"), result.sidebarWidth);
    result.editorTopHeight = readIntValue(
        store_, key(workspaceRoot, "editorTopHeight"), result.editorTopHeight);
    if (const auto value = readTypedValue<std::int64_t>(
            store_, key(workspaceRoot, "sidebarDestination"))) {
        if (*value >= std::numeric_limits<int>::min() &&
            *value <= std::numeric_limits<int>::max()) {
            result.sidebarDestination = static_cast<SidebarDestination>(
                static_cast<int>(*value));
        }
    }
    if (const auto value = readTypedValue<std::int64_t>(
            store_, key(workspaceRoot, "bottomToolKind"))) {
        if (*value >= std::numeric_limits<int>::min() &&
            *value <= std::numeric_limits<int>::max()) {
            result.bottomToolKind = static_cast<BottomToolKind>(
                static_cast<int>(*value));
        }
    }
    if (const auto value = readTypedValue<bool>(
            store_, key(workspaceRoot, "bottomVisible"))) {
        result.bottomVisible = *value;
    }
    return result;
}

bool WorkbenchLayoutPersistence::save(const std::string& workspaceRoot,
                                      const WorkbenchLayoutState& state,
                                      std::string& error) {
    if (workspaceRoot.empty()) {
        error = "workspace root is empty";
        return false;
    }
    if (!writeValue(store_, key(workspaceRoot, "sidebarWidth"),
                    static_cast<std::int64_t>(state.sidebarWidth), error)) {
        return false;
    }
    if (!writeValue(store_, key(workspaceRoot, "editorTopHeight"),
                    static_cast<std::int64_t>(state.editorTopHeight), error)) {
        return false;
    }
    if (!writeValue(store_, key(workspaceRoot, "sidebarDestination"),
                    static_cast<std::int64_t>(state.sidebarDestination), error)) {
        return false;
    }
    if (!writeValue(store_, key(workspaceRoot, "bottomToolKind"),
                    static_cast<std::int64_t>(state.bottomToolKind), error)) {
        return false;
    }
    return writeValue(store_, key(workspaceRoot, "bottomVisible"),
                      state.bottomVisible, error);
}

}
