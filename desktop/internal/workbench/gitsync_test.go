package workbench

import (
	"os"
	"path/filepath"
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
	h = newHarness(t, gitKernel{core.NewClient()})
	h.app.delays = logDelays{}
	h.open(dir)
	h.app.layout.gitTab = gitTabLog
	h.settle()
	if !h.app.project.log.started {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	p = h.app.project
	if p.log.current != "main" {
		t.Fatalf("log current branch = %q, want main", p.log.current)
	}
	return h, p, dir, other
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
	h.app.fetchAll(p)
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
	h.app.updateCurrentBranch(p)
	h.settle()
	h.settle()
	if want := h.app.text.Sync.UpToDate("main"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}

	publishCommit(t, other, "one.txt")
	h.app.updateCurrentBranch(p)
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
	h.app.updateCurrentBranch(p)
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
