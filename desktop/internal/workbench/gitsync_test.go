package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// syncFixture opens a repository that tracks a local bare origin on the log tab, and
// returns a second clone that publishes commits to that origin.
func syncFixture(t *testing.T) (h *harness, p *project, dir, other string) {
	t.Helper()
	dir = newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	bare := filepath.Join(t.TempDir(), "origin.git")
	gitRun(t, dir, "clone", "--bare", dir, bare)
	gitRun(t, dir, "remote", "add", "origin", bare)
	gitRun(t, dir, "fetch", "origin")
	gitRun(t, dir, "branch", "-u", "origin/main", "main")
	other = filepath.Join(t.TempDir(), "other")
	gitRun(t, dir, "clone", bare, other)
	h, p = openGitLogFixture(t, dir)
	return h, p, dir, other
}

func openGitLogFixture(t *testing.T, dir string) (*harness, *project) {
	t.Helper()
	h := newHarness(t, gitKernel{core.NewClient()})
	h.app.delays = logDelays{}
	h.app.openProject(dir)
	p := h.app.project
	h.app.layout.gitTab = gitTabLog
	h.await("repository status", func() bool { return p.git.loaded })
	if !p.git.isRepository() {
		t.Fatalf("fixture did not load a repository: %v", p.git.err)
	}
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.sendClick(center(h.button(itemGit)))
	}
	h.awaitLogReady(p)
	return h, p
}

func (h *harness) awaitLogReady(p *project) {
	h.t.Helper()
	h.await("Git log", func() bool { return p.log.started && !p.log.loading && p.log.current != "" })
}

func publishCommit(t *testing.T, clone, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(clone, name), []byte(name+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, clone, "add", name)
	gitRun(t, clone, "commit", "-m", name)
	gitRun(t, clone, "push", "origin", "HEAD")
}

func TestLogFetchAllRefreshesTheReferences(t *testing.T) {
	h, p, dir, other := syncFixture(t)
	publishCommit(t, other, "fetched.txt")
	h.app.fetchAll(p, surfaceButton)
	if !p.log.sync.busy {
		t.Fatal("no operation is shown while the fetch runs")
	}
	h.settle()
	h.settle()
	if p.log.sync.busy || h.app.notice != h.app.text.Sync.Fetched {
		t.Fatalf("after the fetch: busy %v, notice %q", p.log.sync.busy, h.app.notice)
	}
	if got := gitRun(t, dir, "rev-list", "--count", "main..origin/main"); got != "1" {
		t.Fatalf("commits fetched = %q, want 1", got)
	}
}

func TestLogFetchOptionsFetchOneRemoteAndReportAFailure(t *testing.T) {
	h, p, _, _ := syncFixture(t)
	h.app.openFetchOptions(p)
	h.settle()
	s := &p.log.sync
	s.onlyRemote = true
	s.remote.SetText("missing")
	h.settle()
	h.app.submitFetchOptions(p)
	h.settle()
	h.settle()
	if s.dialog != syncDialogNone || s.busy {
		t.Fatalf("dialog %v busy %v after submitting", s.dialog, s.busy)
	}
	if !strings.HasPrefix(h.app.notice, strings.SplitN(h.app.text.Sync.FetchFailed("\x00"), "\x00", 2)[0]) {
		t.Fatalf("notice = %q, want a fetch failure", h.app.notice)
	}
	h.app.openFetchOptions(p)
	h.settle()
	s.onlyRemote = true
	s.remote.SetText("origin")
	s.tags = 1
	h.app.submitFetchOptions(p)
	h.settle()
	h.settle()
	if h.app.notice != h.app.text.Sync.Fetched {
		t.Fatalf("notice = %q, want the fetch to succeed for origin", h.app.notice)
	}
}

func TestLogUpdateBranchFastForwardsAndAsksWhenDiverged(t *testing.T) {
	h, p, dir, other := syncFixture(t)
	h.app.updateCurrentBranch(p, surfaceButton)
	h.settle()
	h.settle()
	if want := h.app.text.Sync.UpToDate("main"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}

	publishCommit(t, other, "one.txt")
	h.app.updateCurrentBranch(p, surfaceButton)
	h.settle()
	h.settle()
	if want := h.app.text.Sync.Updated("main"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
	if _, err := os.Stat(filepath.Join(dir, "one.txt")); err != nil {
		t.Fatalf("the update did not bring the commit: %v", err)
	}

	publishCommit(t, other, "two.txt")
	if err := os.WriteFile(filepath.Join(dir, "mine.txt"), []byte("mine\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", "mine.txt")
	gitRun(t, dir, "commit", "-m", "mine")
	h.app.updateCurrentBranch(p, surfaceButton)
	h.settle()
	h.settle()
	s := &p.log.sync
	if s.dialog != syncDialogDiverged || s.preflight.Ahead != 1 || s.preflight.Behind != 1 {
		t.Fatalf("dialog %v preflight %+v, want the diverged question for 1/1", s.dialog, s.preflight)
	}
	h.app.resolveDiverged(p, core.GitPullRebase)
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "rev-list", "--count", "origin/main..main"); got != "1" {
		t.Fatalf("local commits over the upstream after the rebase = %q, want 1", got)
	}
}

func TestLogShowChangesOpensTheCommitToolWindow(t *testing.T) {
	h, _, _, _ := syncFixture(t)
	h.app.showChanges()
	h.settle()
	if !h.app.chrome.isOpen(catalogIndex[itemCommit]) {
		t.Fatal("the Commit tool window is not open")
	}
}

func TestLogFetchOptionsShowTheRepositoryConfigurationWithoutWritingIt(t *testing.T) {
	h, p, dir, _ := syncFixture(t)
	gitRun(t, dir, "config", "lithe.fetch.prune", "false")
	gitRun(t, dir, "config", "lithe.fetch.tags", "none")
	gitRun(t, dir, "config", "lithe.fetch.submodules", "no")
	configPath := filepath.Join(dir, ".git", "config")
	before, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	h.app.openFetchOptions(p)
	s := &p.log.sync
	if !s.settingsLoading {
		t.Fatal("the dialog does not wait for the repository's configuration")
	}
	h.settle()
	h.settle()
	if s.settingsLoading || !s.keepStale || s.onlyRemote {
		t.Fatalf("loading %v keepStale %v onlyRemote %v, want the configured prune off", s.settingsLoading, s.keepStale, s.onlyRemote)
	}
	options := s.fetchOptions()
	if options.Prune || options.Tags != core.GitFetchTagsNone || options.Submodules != core.GitFetchSubmodulesNo {
		t.Fatalf("options = %+v, want what lithe.fetch.* selects", options)
	}
	after, err := os.ReadFile(configPath)
	if err != nil || string(before) != string(after) {
		t.Fatalf("opening the dialog changed the configuration: %v", err)
	}
}

func TestSyncProgressKeepsOnlyTheLatestPhaseOfTheRunningOperation(t *testing.T) {
	h, p, _, _ := syncFixture(t)
	s := &p.log.sync
	relay := &syncProgressRelay{}
	s.busy, s.relay = true, relay
	percent := func(v int) *int { return &v }
	h.app.postSyncProgress(p, relay, core.GitProgress{Stage: "counting", Percent: percent(10)})
	h.app.postSyncProgress(p, relay, core.GitProgress{Stage: "receiving", Percent: percent(42)})
	h.settle()
	if !s.hasProgress || s.progress.Stage != "receiving" || *s.progress.Percent != 42 {
		t.Fatalf("progress = %+v, want the latest phase", s.progress)
	}
	if got, want := h.app.syncProgressWords(s), h.app.text.Sync.Progress("receiving", 42); got == "" || got != want {
		t.Fatalf("status words = %q, want %q", got, want)
	}
	// A phase that arrives after the operation ended must not show on the next one.
	s.busy, s.relay, s.hasProgress = false, nil, false
	h.app.postSyncProgress(p, relay, core.GitProgress{Stage: "writing"})
	h.settle()
	if s.hasProgress {
		t.Fatal("a late phase leaked into the idle state")
	}
}

func TestLogUpdateSelectedBranchFastForwardsWithoutCheckingItOut(t *testing.T) {
	h, p, dir, other := syncFixture(t)
	h.app.reduceChrome(core.SetChromeOpen(itemGit, true))
	h.settleChain()
	gitRun(t, dir, "branch", "--track", "side", "origin/main")
	publishCommit(t, other, "side.txt")
	h.app.loadLog(p)
	h.settle()
	h.settle()
	side, ok := p.log.findReference("refs/heads/side")
	if !ok || side.UpstreamShortName != "origin/main" {
		t.Fatalf("side = %+v (%v), want a branch tracking origin/main", side, ok)
	}
	p.log.refSelected = side.FullName
	h.settle()
	h.clickNamed(h.app.text.Git.UpdateBranch)
	h.settle()
	h.settle()
	if want := h.app.text.Sync.Updated("side"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
	if got := gitRun(t, dir, "rev-parse", "side"); got != gitRun(t, dir, "rev-parse", "origin/main") {
		t.Fatal("side was not fast-forwarded to its upstream")
	}
	if got := gitRun(t, dir, "branch", "--show-current"); got != "main" {
		t.Fatalf("the update checked out %q", got)
	}
}

func TestLogNewAndDeleteBranchFromTheBranchesPane(t *testing.T) {
	h, p, dir, _ := syncFixture(t)
	h.app.reduceChrome(core.SetChromeOpen(itemGit, true))
	h.settleChain()
	h.clickNamed(h.app.text.Git.NewBranch)
	h.settle()
	b := &h.app.branch
	if b.dialog != branchDialogCreate || b.target.ShortName != "main" {
		t.Fatalf("dialog %v from %+v, want the create dialog from main", b.dialog, b.target)
	}
	b.name.SetText("topic")
	b.checkout = false
	h.settle()
	h.app.submitCreate(p)
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "branch", "--list", "topic"); !strings.Contains(got, "topic") {
		t.Fatalf("no topic branch: %q", got)
	}
	topic, ok := p.log.findReference("refs/heads/topic")
	if !ok {
		t.Fatal("the log did not list the new branch")
	}
	v := &h.app.logView
	i := slices.IndexFunc(v.refItems, func(r logRefRow) bool { return r.kind == logRefReference && r.short == "topic" })
	if i < 0 {
		t.Fatal("the reference pane does not show topic")
	}
	h.click(center(h.topHit(v.refs.RowID(i))))
	h.settleChain()
	if p.log.reference != topic.FullName || p.log.referenceLabel != "topic" || p.log.refSelected != topic.FullName {
		t.Fatalf("after clicking topic: ref=%q label=%q selected=%q", p.log.reference, p.log.referenceLabel, p.log.refSelected)
	}

	h.clickNamed(h.app.text.Git.DeleteBranch)
	h.settle()
	if b.dialog != branchDialogDelete || b.target.FullName != topic.FullName {
		t.Fatalf("dialog %v for %+v, want the delete confirmation of topic", b.dialog, b.target)
	}
	h.click(center(h.popupHit(h.app.text.Branch.DeleteButton)))
	h.settleChain()
	if p.log.err != nil {
		t.Fatalf("log err after deleting filtered branch: %v", p.log.err)
	}
	if p.log.reference != "" || p.log.referenceLabel != "" || p.log.refSelected != "" {
		t.Fatalf("after deleting topic: ref=%q label=%q selected=%q, want all cleared", p.log.reference, p.log.referenceLabel, p.log.refSelected)
	}
	if len(p.log.commits) == 0 {
		t.Fatal("the log cleared commits after deleting the filtered branch")
	}
	if _, ok := p.log.findReference("refs/heads/main"); !ok {
		t.Fatal("the reference pane lost main after deleting the filtered branch")
	}

	// Renaming the filtered current branch keeps the log on the renamed reference.
	mainIdx := slices.IndexFunc(v.refItems, func(r logRefRow) bool { return r.kind == logRefReference && r.short == "main" })
	if mainIdx < 0 {
		t.Fatal("the reference pane does not show main")
	}
	h.click(center(h.topHit(v.refs.RowID(mainIdx))))
	h.settleChain()
	if p.log.reference != "refs/heads/main" {
		t.Fatalf("after clicking main: ref=%q, want refs/heads/main", p.log.reference)
	}
	h.logRefMenu("main")
	h.click(center(h.popupHit(h.app.text.Branch.Rename)))
	h.settle()
	if b.dialog != branchDialogRename || b.target.FullName != "refs/heads/main" {
		t.Fatalf("dialog %v for %+v, want the rename dialog of main", b.dialog, b.target)
	}
	b.name.SetText("trunk")
	h.settle()
	h.app.submitRename(p)
	h.settleChain()
	if p.log.err != nil {
		t.Fatalf("log err after renaming filtered branch: %v", p.log.err)
	}
	if p.log.reference != "refs/heads/trunk" || p.log.referenceLabel != "trunk" || p.log.refSelected != "refs/heads/trunk" {
		t.Fatalf("after renaming main: ref=%q label=%q selected=%q", p.log.reference, p.log.referenceLabel, p.log.refSelected)
	}

	// If a filtered reference disappears outside the UI, reloading the log falls back to all
	// references instead of failing git.historyPage and wiping the reference pane.
	gitRun(t, dir, "branch", "ext")
	h.app.setLogReference(p, "refs/heads/ext", "ext")
	h.settleChain()
	gitRun(t, dir, "branch", "-D", "ext")
	h.app.loadLog(p)
	h.settleChain()
	if p.log.err != nil {
		t.Fatalf("log err after external branch deletion: %v", p.log.err)
	}
	if p.log.reference != "" || p.log.referenceLabel != "" {
		t.Fatalf("after external deletion: ref=%q label=%q, want cleared", p.log.reference, p.log.referenceLabel)
	}
	if len(p.log.commits) == 0 {
		t.Fatal("the log has no commits after external deletion fallback")
	}
}
