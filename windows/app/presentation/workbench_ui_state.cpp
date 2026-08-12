#include "workbench_ui_state.h"

#include <algorithm>
#include <unordered_set>

namespace lithe::windows {
namespace {

int clampValue(int value, int minimum, int maximum) {
    return std::min(std::max(value, minimum), maximum);
}

SidebarDestination normalizeSidebarDestination(SidebarDestination value) {
    switch (value) {
    case SidebarDestination::Project:
    case SidebarDestination::Search:
    case SidebarDestination::Git:
        return value;
    }
    return SidebarDestination::Project;
}

BottomToolKind normalizeBottomTool(BottomToolKind value) {
    switch (value) {
    case BottomToolKind::Terminal:
    case BottomToolKind::Build:
    case BottomToolKind::Problems:
    case BottomToolKind::Debug:
    case BottomToolKind::Git:
    case BottomToolKind::Diff:
        return value;
    }
    return BottomToolKind::Terminal;
}

int normalizeSidebarWidth(int requestedWidth, int availableWidth) {
    const int usableWidth = std::max(availableWidth, kMinimumUsablePaneSize * 2);
    if (usableWidth < kSidebarMinWidth + kMinimumUsablePaneSize) {
        return usableWidth - kMinimumUsablePaneSize;
    }

    const int maximumWidth = std::min(
        kSidebarMaxWidth, usableWidth - kMinimumUsablePaneSize);
    return clampValue(requestedWidth, kSidebarMinWidth, maximumWidth);
}

int normalizeEditorTopHeight(int requestedHeight, int availableHeight, bool& bottomVisible) {
    const int usableHeight = std::max(availableHeight, kMinimumUsablePaneSize * 2);
    const bool requestedBottomVisible = bottomVisible;
    if (requestedBottomVisible && usableHeight >= kEditorTopMinHeight + kBottomToolMinHeight) {
        const int maximumEditorHeight = usableHeight - kBottomToolMinHeight;
        return clampValue(requestedHeight, kEditorTopMinHeight, maximumEditorHeight);
    }

    bottomVisible = false;
    if (requestedBottomVisible) return usableHeight;
    if (usableHeight < kEditorTopMinHeight) return usableHeight;
    return clampValue(requestedHeight, kEditorTopMinHeight, usableHeight);
}

} // namespace

WorkbenchLayoutState normalizeWorkbenchLayout(WorkbenchLayoutState state,
                                               int availableWidth,
                                               int availableHeight) {
    state.sidebarDestination = normalizeSidebarDestination(state.sidebarDestination);
    state.bottomToolKind = normalizeBottomTool(state.bottomToolKind);
    state.sidebarWidth = normalizeSidebarWidth(state.sidebarWidth, availableWidth);
    state.editorTopHeight = normalizeEditorTopHeight(
        state.editorTopHeight, availableHeight, state.bottomVisible);
    return state;
}

std::vector<GitChangeRow> buildGitChangeRows(
    const GitStatusDto& status,
    const std::vector<std::string>& blockingPaths,
    bool blockingOnly) {
    const std::unordered_set<std::string> blocking(
        blockingPaths.begin(), blockingPaths.end());
    std::unordered_set<std::string> displayed;
    std::vector<GitChangeRow> rows;
    rows.reserve(status.changes.size() + blocking.size());
    for (const auto& change : status.changes) {
        const bool isBlocking = blocking.contains(change.path);
        if (blockingOnly && !isBlocking) continue;
        displayed.insert(change.path);
        const std::string area = isBlocking ? "!"
            : change.staged ? "S" : change.untracked ? "U" : "W";
        rows.push_back(GitChangeRow{
            change.path,
            area + "  " + (isBlocking ? "BLOCKED" : change.status) + "  " + change.path,
            isBlocking,
        });
    }
    for (const auto& path : blockingPaths) {
        if (!displayed.insert(path).second) continue;
        rows.push_back(GitChangeRow{path, "!  BLOCKED  " + path, true});
    }
    return rows;
}

} // namespace lithe::windows
