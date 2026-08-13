#pragma once

#include "core_dto.h"

#include <string>
#include <vector>

namespace lithe::windows {

enum class SidebarDestination : int {
    Project = 0,
    Search = 1,
    Git = 2,
};

enum class BottomToolKind : int {
    Terminal = 0,
    Build = 1,
    Problems = 2,
    Debug = 3,
    Git = 4,
    Diff = 5,
};

inline constexpr int kSidebarMinWidth = 220;
inline constexpr int kSidebarMaxWidth = 520;
inline constexpr int kDefaultSidebarWidth = 280;
inline constexpr int kEditorTopMinHeight = 220;
inline constexpr int kDefaultEditorTopHeight = 400;
inline constexpr int kBottomToolMinHeight = 260;
inline constexpr int kDefaultBottomToolHeight = 300;
inline constexpr int kMinimumUsablePaneSize = 1;

struct WorkbenchLayoutState {
    int sidebarWidth = kDefaultSidebarWidth;
    int editorTopHeight = kDefaultEditorTopHeight;
    SidebarDestination sidebarDestination = SidebarDestination::Project;
    BottomToolKind bottomToolKind = BottomToolKind::Terminal;
    bool bottomVisible = true;
};

WorkbenchLayoutState normalizeWorkbenchLayout(WorkbenchLayoutState state,
                                               int availableWidth,
                                               int availableHeight);

struct GitChangeRow {
    std::string path;
    std::string label;
    bool blocking = false;
    bool staged = false;
    std::string status;
};

struct GitChangeGroups {
    std::vector<GitChangeRow> staged;
    std::vector<GitChangeRow> working;
};

std::vector<GitChangeRow> buildGitChangeRows(
    const GitStatusDto& status,
    const std::vector<std::string>& blockingPaths,
    bool blockingOnly);

GitChangeGroups buildGitChangeGroups(
    const GitStatusDto& status,
    const std::vector<std::string>& blockingPaths,
    bool blockingOnly);

} // namespace lithe::windows
