package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// changeOf is the status entry of path in the project's Git status.
func changeOf(t *testing.T, p *project, path string) core.GitChange {
	t.Helper()
	for _, change := range p.git.status.Changes {
		if change.Path == path {
			return change
		}
	}
	t.Fatalf("status has no change for %s: %+v", path, p.git.status.Changes)
	return core.GitChange{}
}

func TestBlockLine(t *testing.T) {
	for id, want := range map[string]int{"line-2": 2, "line-0": 0, "line-123": 123} {
		if got, ok := blockLine(id); !ok || got != want {
			t.Errorf("blockLine(%q) = %d, %v; want %d", id, got, ok, want)
		}
	}
	for _, id := range []string{"", "line-", "hunk-1", "line-x"} {
		if _, ok := blockLine(id); ok {
			t.Errorf("blockLine(%q) succeeded, want a refusal", id)
		}
	}
}

func TestRollbackDialogRestoresTheChange(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.app.openRollback(p, []core.GitChange{changeOf(t, p, "changed.txt")})
	h.app.post(func(*App) {})
	h.settle()
	if !h.shows(i18n.Shared(h.app.language(), "git.rollback.title")) {
		t.Fatal("the rollback confirmation is not shown")
	}
	h.app.runRollback(p)
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "status", "--porcelain"); got != "" {
		t.Fatalf("status after the rollback = %q, want clean", got)
	}
	if p.review.rollback.open {
		t.Fatal("the rollback dialog stayed open")
	}
}

func TestBlameDialogListsEveryLine(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.app.openBlame(p, "changed.txt")
	h.settle()
	b := &p.review.blame
	if b.err != "" || len(b.lines) != 1 || len(b.text) != 1 || b.text[0] != "second" {
		t.Fatalf("blame = %+v, want one uncommitted line of the saved text", b)
	}
	if !b.lines[0].Uncommitted() {
		t.Fatalf("blame line = %+v, want it uncommitted", b.lines[0])
	}
}

func TestPushDialogReviewsAndPushes(t *testing.T) {
	dir := newTestRepository(t)
	bare := filepath.Join(t.TempDir(), "origin.git")
	gitRun(t, dir, "clone", "--bare", dir, bare)
	gitRun(t, dir, "remote", "add", "origin", bare)
	gitRun(t, dir, "push", "-u", "origin", "main")
	gitRun(t, dir, "commit", "-am", "ahead")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	h.app.openPush(p)
	h.settle()
	s := &p.review.push
	if s.err != "" || !s.hasPrev || len(s.preview.Commits) != 1 || !s.canPush() {
		t.Fatalf("push dialog = %+v, want a reviewed single commit", s)
	}
	if !h.shows("origin/main") {
		t.Fatal("the push dialog does not show its destination")
	}
	h.app.submitPush(p)
	for range 4 {
		h.settle()
	}
	if s.open || s.busy {
		t.Fatalf("push dialog after the push = open %v busy %v, want it closed", s.open, s.busy)
	}
	if got := gitRun(t, bare, "log", "-1", "--format=%s", "main"); got != "ahead" {
		t.Fatalf("remote tip = %q, want the pushed commit", got)
	}
}

func TestPushDialogWithoutRemoteReportsIt(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.app.openPush(p)
	h.settle()
	s := &p.review.push
	if s.err == "" || s.canPush() {
		t.Fatalf("push dialog without a remote = %+v, want an error and no push", s)
	}
}

func TestToolsDialogStashesAndListsRepositories(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	h.app.openTools(p, toolsStashes)
	h.settle()
	tools := &p.review.tools
	if tools.err != "" || len(tools.stashes) != 0 || len(tools.repositories) == 0 {
		t.Fatalf("tools = %+v, want no stash and a repository", tools)
	}

	tools.stashMessage.SetText("parked")
	h.app.stashChanges(p)
	h.settle()
	h.settle()
	if len(tools.stashes) != 1 || !strings.Contains(tools.stashes[0].Message, "parked") {
		t.Fatalf("stashes after the stash = %+v, want the parked one", tools.stashes)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); got != "" {
		t.Fatalf("status after the stash = %q, want clean", got)
	}
	h.app.stashAction(p, tools.stashes[0], "pop")
	h.settle()
	h.settle()
	if len(tools.stashes) != 0 || gitRun(t, dir, "status", "--porcelain") != "M changed.txt" {
		t.Fatalf("after the pop: stashes %+v, status %q", tools.stashes, gitRun(t, dir, "status", "--porcelain"))
	}
}

func TestUntrackedDirectoryListingStagesAFile(t *testing.T) {
	dir := newTestRepository(t)
	bulk := filepath.Join(dir, "bulk")
	if err := os.MkdirAll(filepath.Join(bulk, "inner"), 0o755); err != nil {
		t.Fatal(err)
	}
	for i := range 101 {
		name := filepath.Join(bulk, "f"+string(rune('a'+i%26))+strings.Repeat("x", i/26)+".txt")
		if err := os.WriteFile(name, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	summary := changeOf(t, p, "bulk/")
	if summary.UntrackedFileCount < 100 {
		t.Fatalf("summary = %+v, want a summarized directory", summary)
	}
	h.app.openChange(p, summary)
	h.settle()
	u := &p.review.untracked
	if u.err != "" || len(u.changes) == 0 {
		t.Fatalf("untracked listing = %+v, want its files", u)
	}
	first := u.changes[0]
	h.app.stageUntracked(p, first)
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); !strings.Contains(got, strings.TrimSuffix(first.Path, "/")) {
		t.Fatalf("staged after the listing's stage = %q, want %q", got, first.Path)
	}
}
