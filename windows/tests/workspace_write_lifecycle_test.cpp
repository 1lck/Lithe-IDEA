#include "workspace_write_lifecycle.h"

#include <cassert>

using namespace lithe::windows;
using namespace lithe::windows::app;

int main() {
    WorkspaceWriteLifecycle lifecycle;
    // Models a nested operation such as Commit and Push. Only the outer end
    // publishes deferred watcher changes and requests the shared refresh.
    const auto outer = lifecycle.begin();
    const auto inner = lifecycle.begin();
    assert(lifecycle.isFrozen() && lifecycle.depth() == 2);
    assert(!lifecycle.observeChanges({
        {"src/Main.java", DirectoryChangeSource::ChangeKind::Modified},
        {"src/Main.java", DirectoryChangeSource::ChangeKind::Modified},
        {"src/New.java", DirectoryChangeSource::ChangeKind::Added},
    }));
    assert(!lifecycle.requestRefresh());
    const auto nested = lifecycle.end(inner);
    assert(!nested.shouldRefresh && nested.deferredChanges.empty());
    const auto completed = lifecycle.end(outer);
    assert(completed.shouldRefresh);
    assert(completed.deferredChanges.size() == 2);
    assert(completed.deferredChanges[0].path == "src/Main.java");
    assert(completed.deferredChanges[1].path == "src/New.java");
    assert(!lifecycle.isFrozen());
    assert(!lifecycle.end(outer).shouldRefresh);

    const auto immediate = lifecycle.observeChanges({
        {"README.md", DirectoryChangeSource::ChangeKind::Modified},
    });
    assert(immediate && immediate->size() == 1);
    assert(lifecycle.requestRefresh());

    const auto suppressed = lifecycle.begin(false);
    assert(!lifecycle.observeChanges({
        {"generated.txt", DirectoryChangeSource::ChangeKind::Modified},
    }));
    const auto suppressedCompletion = lifecycle.end(suppressed);
    assert(suppressedCompletion.shouldRefresh);
    assert(suppressedCompletion.deferredChanges.empty());
    assert(!lifecycle.observeChanges({
        {"generated.txt", DirectoryChangeSource::ChangeKind::Modified},
    }));

    const auto rescan = lifecycle.begin();
    assert(!lifecycle.observeChanges({
        {"a", DirectoryChangeSource::ChangeKind::Modified},
        {".", DirectoryChangeSource::ChangeKind::RescanRequired},
        {"b", DirectoryChangeSource::ChangeKind::Added},
    }));
    const auto rescanned = lifecycle.end(rescan, false);
    assert(rescanned.shouldRefresh);
    assert(rescanned.deferredChanges.size() == 1);
    assert(rescanned.deferredChanges[0].kind ==
           DirectoryChangeSource::ChangeKind::RescanRequired);

    const auto abandoned = lifecycle.begin();
    lifecycle.reset();
    assert(!lifecycle.isFrozen());
    assert(!lifecycle.end(abandoned).shouldRefresh);
    return 0;
}
