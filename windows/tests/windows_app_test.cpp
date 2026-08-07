#include "editor_position.h"
#include "workspace_paths.h"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <stdexcept>

using namespace lithe::windows::app;

int main() {
    const auto relative = RelativePath::parse("src/Main.java");
    assert(relative && relative->value() == "src/Main.java");
    assert(!RelativePath::parse("../outside"));
    assert(!RelativePath::parse("C:/absolute"));
    const auto gitRef = GitRef::parse("origin/main");
    assert(gitRef && gitRef->value() == "origin/main");
    assert(!GitRef::parse("-bad"));

    const auto root = (std::filesystem::temp_directory_path() / "lithe-workspace-path-test")
        .lexically_normal();
    const WorkspacePaths paths(root);

    assert(paths.contains(root));
    assert(paths.contains(root / "src" / "Main.java"));
    assert(!paths.contains(root.parent_path() / "outside.txt"));
    assert(paths.toRelative(root) && paths.toRelative(root)->empty());
    assert(paths.toRelative(root / "src" / "Main.java") ==
           std::optional<std::string>("src/Main.java"));
    assert(paths.toAbsolute("src/Main.java") == (root / "src" / "Main.java").lexically_normal());

    bool escaped = false;
    try {
        (void)paths.toAbsolute("../outside.txt");
    } catch (const std::invalid_argument&) {
        escaped = true;
    }
    assert(escaped);

    const auto oneBased = EditorPosition::fromOneBased(1, 1);
    assert(oneBased.line == 0 && oneBased.utf16Column == 0);
    assert(oneBased.displayLine() == 1 && oneBased.displayColumn() == 1);
    const auto guarded = EditorPosition::fromOneBased(0, 0);
    assert(guarded.line == 0 && guarded.utf16Column == 0);
    const auto zeroBased = EditorPosition::fromZeroBased(4, 7);
    assert(zeroBased.displayLine() == 5 && zeroBased.displayColumn() == 8);
    return 0;
}
