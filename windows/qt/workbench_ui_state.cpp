#include "workbench_ui_state.h"

#include <algorithm>

namespace lithe::windows {
namespace {

int clampValue(int value, int minimum, int maximum) {
    return std::min(std::max(value, minimum), maximum);
}

template <typename Enum>
Enum normalizeEnum(Enum value, Enum fallback) {
    switch (value) {
    case Enum::Project:
    case Enum::Search:
    case Enum::Git:
        return value;
    default:
        return fallback;
    }
}

template <typename Enum>
Enum normalizeBottomTool(Enum value, Enum fallback) {
    switch (value) {
    case Enum::Terminal:
    case Enum::Build:
    case Enum::Problems:
    case Enum::Debug:
    case Enum::Git:
    case Enum::Diff:
        return value;
    default:
        return fallback;
    }
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
    if (requestedBottomVisible) {
        return usableHeight;
    }
    if (usableHeight < kEditorTopMinHeight) {
        return usableHeight;
    }
    return clampValue(requestedHeight, kEditorTopMinHeight, usableHeight);
}

}

WorkbenchLayoutState normalizeWorkbenchLayout(WorkbenchLayoutState state,
                                               int availableWidth,
                                               int availableHeight) {
    state.sidebarDestination = normalizeEnum(
        state.sidebarDestination, SidebarDestination::Project);
    state.bottomToolKind = normalizeBottomTool(
        state.bottomToolKind, BottomToolKind::Terminal);
    state.sidebarWidth = normalizeSidebarWidth(state.sidebarWidth, availableWidth);
    state.editorTopHeight = normalizeEditorTopHeight(
        state.editorTopHeight, availableHeight, state.bottomVisible);
    return state;
}

}
