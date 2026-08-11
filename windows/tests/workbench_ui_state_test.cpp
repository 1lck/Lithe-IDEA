#include "workbench_ui_state.h"

#include <cassert>

int main() {
    using namespace lithe::windows;

    assert(static_cast<int>(SidebarDestination::Project) == 0);
    assert(static_cast<int>(SidebarDestination::Search) == 1);
    assert(static_cast<int>(SidebarDestination::Git) == 2);
    assert(static_cast<int>(BottomToolKind::Terminal) == 0);
    assert(static_cast<int>(BottomToolKind::Build) == 1);
    assert(static_cast<int>(BottomToolKind::Problems) == 2);
    assert(static_cast<int>(BottomToolKind::Debug) == 3);
    assert(static_cast<int>(BottomToolKind::Git) == 4);
    assert(static_cast<int>(BottomToolKind::Diff) == 5);

    const WorkbenchLayoutState defaults;
    assert(defaults.sidebarWidth == 280);
    assert(defaults.editorTopHeight == 400);
    assert(defaults.sidebarDestination == SidebarDestination::Project);
    assert(defaults.bottomToolKind == BottomToolKind::Terminal);
    assert(defaults.bottomVisible);

    const auto normalized = normalizeWorkbenchLayout({
        .sidebarWidth = 20,
        .editorTopHeight = 100,
        .sidebarDestination = static_cast<SidebarDestination>(99),
        .bottomToolKind = static_cast<BottomToolKind>(99),
        .bottomVisible = true,
    }, 1200, 900);
    assert(normalized.sidebarWidth == 220);
    assert(normalized.editorTopHeight == 220);
    assert(normalized.sidebarDestination == SidebarDestination::Project);
    assert(normalized.bottomToolKind == BottomToolKind::Terminal);
    assert(normalized.bottomVisible);
    assert(900 - normalized.editorTopHeight >= 260);

    const auto wideSidebar = normalizeWorkbenchLayout({
        .sidebarWidth = 900,
        .editorTopHeight = 400,
        .sidebarDestination = SidebarDestination::Search,
        .bottomToolKind = BottomToolKind::Build,
        .bottomVisible = true,
    }, 1600, 900);
    assert(wideSidebar.sidebarWidth == 520);
    assert(wideSidebar.sidebarDestination == SidebarDestination::Search);
    assert(wideSidebar.bottomToolKind == BottomToolKind::Build);
    assert(wideSidebar.bottomVisible);

    const auto debugTool = normalizeWorkbenchLayout({
        .sidebarWidth = 300,
        .editorTopHeight = 400,
        .sidebarDestination = SidebarDestination::Project,
        .bottomToolKind = BottomToolKind::Debug,
        .bottomVisible = true,
    }, 1200, 900);
    assert(debugTool.bottomToolKind == BottomToolKind::Debug);

    const auto gitTool = normalizeWorkbenchLayout({
        .sidebarWidth = 300,
        .editorTopHeight = 400,
        .sidebarDestination = SidebarDestination::Project,
        .bottomToolKind = BottomToolKind::Git,
        .bottomVisible = true,
    }, 1200, 900);
    assert(gitTool.bottomToolKind == BottomToolKind::Git);

    const auto diffTool = normalizeWorkbenchLayout({
        .sidebarWidth = 300,
        .editorTopHeight = 400,
        .sidebarDestination = SidebarDestination::Project,
        .bottomToolKind = BottomToolKind::Diff,
        .bottomVisible = true,
    }, 1200, 900);
    assert(diffTool.bottomToolKind == BottomToolKind::Diff);

    const auto constrainedBottom = normalizeWorkbenchLayout({
        .sidebarWidth = 300,
        .editorTopHeight = 700,
        .sidebarDestination = SidebarDestination::Git,
        .bottomToolKind = BottomToolKind::Problems,
        .bottomVisible = true,
    }, 1200, 900);
    assert(constrainedBottom.editorTopHeight == 640);
    assert(900 - constrainedBottom.editorTopHeight == 260);
    assert(constrainedBottom.sidebarDestination == SidebarDestination::Git);
    assert(constrainedBottom.bottomToolKind == BottomToolKind::Problems);
    assert(constrainedBottom.bottomVisible);

    const auto explicitlyHidden = normalizeWorkbenchLayout({
        .sidebarWidth = 300,
        .editorTopHeight = 400,
        .sidebarDestination = SidebarDestination::Project,
        .bottomToolKind = BottomToolKind::Terminal,
        .bottomVisible = false,
    }, 1200, 900);
    assert(!explicitlyHidden.bottomVisible);
    assert(explicitlyHidden.editorTopHeight == 400);

    const auto hiddenBottom = normalizeWorkbenchLayout({
        .sidebarWidth = 300,
        .editorTopHeight = 100,
        .sidebarDestination = SidebarDestination::Project,
        .bottomToolKind = BottomToolKind::Terminal,
        .bottomVisible = true,
    }, 800, 400);
    assert(!hiddenBottom.bottomVisible);
    assert(hiddenBottom.editorTopHeight == 400);

    const auto narrow = normalizeWorkbenchLayout({
        .sidebarWidth = 520,
        .editorTopHeight = 220,
        .sidebarDestination = SidebarDestination::Search,
        .bottomToolKind = BottomToolKind::Terminal,
        .bottomVisible = true,
    }, 180, 100);
    assert(narrow.sidebarWidth > 0);
    assert(narrow.sidebarWidth < 180);
    assert(narrow.editorTopHeight > 0);
    assert(narrow.editorTopHeight <= 100);
    assert(!narrow.bottomVisible);

    return 0;
}
