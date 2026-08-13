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

    GitStatusDto gitStatus;
    gitStatus.changes = {
        {"src/Working.java", std::nullopt, " M", false, true, false},
        {"src/Staged.java", std::nullopt, "M ", true, false, false},
        {"src/New.java", std::nullopt, "??", false, true, true},
    };
    const auto allChanges = buildGitChangeRows(
        gitStatus, {"src/Working.java", "src/OnlyMarker.java"}, false);
    assert(allChanges.size() == 4);
    assert(allChanges[0].path == "src/Working.java" && allChanges[0].blocking &&
           allChanges[0].label == "!  BLOCKED  src/Working.java");
    assert(allChanges[1].label == "S  M   src/Staged.java");
    assert(allChanges[2].label == "U  ??  src/New.java");
    assert(allChanges[3].path == "src/OnlyMarker.java" && allChanges[3].blocking);

    const auto blockedChanges = buildGitChangeRows(
        gitStatus,
        {"src/OnlyMarker.java", "src/Working.java", "src/Working.java"},
        true);
    assert(blockedChanges.size() == 2);
    assert(blockedChanges[0].path == "src/Working.java");
    assert(blockedChanges[1].path == "src/OnlyMarker.java");

    const auto groups = buildGitChangeGroups(gitStatus, {}, false);
    assert(groups.staged.size() == 1);
    assert(groups.staged[0].path == "src/Staged.java");
    assert(groups.working.size() == 2);
    assert(groups.working[0].path == "src/Working.java");
    assert(groups.working[1].path == "src/New.java");
    assert(groups.staged[0].staged);

    const auto blockingGroups = buildGitChangeGroups(
        gitStatus, {"src/Working.java", "src/OnlyMarker.java"}, true);
    assert(blockingGroups.staged.empty());
    assert(blockingGroups.working.size() == 2);
    assert(blockingGroups.working[0].path == "src/Working.java");
    assert(blockingGroups.working[0].blocking);
    assert(blockingGroups.working[1].path == "src/OnlyMarker.java");
    assert(blockingGroups.working[1].blocking);

    return 0;
}
