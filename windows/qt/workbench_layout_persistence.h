#pragma once

#include "../adapters/ports.h"
#include "workbench_ui_state.h"

#include <string>

namespace lithe::windows {

class WorkbenchLayoutPersistence final {
public:
    explicit WorkbenchLayoutPersistence(KeyValueStore& store);

    // The caller supplies the actual window dimensions to normalizeWorkbenchLayout after loading.
    WorkbenchLayoutState load(const std::string& workspaceRoot) const;
    bool save(const std::string& workspaceRoot,
              const WorkbenchLayoutState& state,
              std::string& error);

private:
    KeyValueStore& store_;

    static std::string key(const std::string& workspaceRoot,
                           const char* field);
};

}
