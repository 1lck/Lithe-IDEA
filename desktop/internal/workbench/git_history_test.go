package workbench

import (
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// logWithTwoCommits opens a repository of two commits, initial and second, on its log.
func logWithTwoCommits(t *testing.T) (*harness, *project, string) {
	t.Helper()
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	if len(p.log.graph.Rows) != 2 {
		t.Fatalf("the log has %d rows, want 2", len(p.log.graph.Rows))
	}
	return h, p, dir
}

// shared is the text of the shared message key in the harness's language.
func (h *harness) shared(key string) string { return i18n.Shared(h.app.language(), key) }

// logRowMenu right-clicks the log row of the commit whose subject is subject.
func (h *harness) logRowMenu(subject string) {
	h.t.Helper()
	point := center(h.pageHit(subject).Bounds)
	if err := h.driver.ClickButton(point.X, point.Y, gfx.PointerButtonSecondary); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
}

func TestLogCommitMenuRevertsTheCommitAfterItIsConfirmed(t *testing.T) {
	h, p, dir := logWithTwoCommits(t)
	second := p.log.graph.Rows[0].CommitHash

	h.logRowMenu("second")
	h.click(center(h.popupHit(h.shared("native.revertCommit"))))
	h.settle()
	if !p.gitHistory.confirm.open || p.gitHistory.confirm.revision != second {
		t.Fatalf("the confirmation is %+v, want it open on %s", p.gitHistory.confirm, second)
	}
	h.click(center(h.popupHit(h.shared("native.revert"))))
	h.await("the revert commit", func() bool {
		return !p.gitHistory.busy && strings.HasPrefix(gitRun(t, dir, "log", "-1", "--format=%s"), "Revert")
	})
	if body := gitRun(t, dir, "log", "-1", "--format=%b"); !strings.Contains(body, second) {
		t.Fatalf("the revert commit's body is %q, want it to name %s", body, second)
	}
}

func TestLogCommitMenuCopiesTheHashesOfEveryChosenCommit(t *testing.T) {
	h, p, _ := logWithTwoCommits(t)
	rows := p.log.graph.Rows
	v := &h.app.logView
	v.chosen.Add(v.hashKey(rows[0].CommitHash))
	v.chosen.Add(v.hashKey(rows[1].CommitHash))
	h.settle()

	if got := h.app.logMenuRevisions(p, 1); len(got) != 2 || got[0] != rows[0].CommitHash || got[1] != rows[1].CommitHash {
		t.Fatalf("the menu of a chosen row acts on %v, want both commits newest first", got)
	}
	h.logRowMenu("initial")
	h.click(center(h.popupHit(h.shared("git.log.copyShortHash"))))
	h.settle()
	want := shortHash(rows[0].CommitHash) + "\n" + shortHash(rows[1].CommitHash)
	if got := h.driver.Clipboard(); got != want {
		t.Fatalf("the clipboard holds %q, want %q", got, want)
	}

	// A row outside the chosen ones acts on its own commit only.
	v.chosen.Clear()
	v.chosen.Add(v.hashKey(rows[0].CommitHash))
	if got := h.app.logMenuRevisions(p, 1); len(got) != 1 || got[0] != rows[1].CommitHash {
		t.Fatalf("the menu of an unchosen row acts on %v, want only %s", got, rows[1].CommitHash)
	}
}

func TestLogCommitMenuPutsANewTagOnTheClickedCommit(t *testing.T) {
	h, p, dir := logWithTwoCommits(t)
	initial := p.log.graph.Rows[1].CommitHash

	h.logRowMenu("initial")
	h.click(center(h.popupHit(h.shared("git.log.newTag"))))
	h.settle()
	h.typeInto(h.shared("desktop.tags.name"), func() { h.app.branch.name.SetText("") }, "v1")
	h.click(center(h.popupHit(h.shared("desktop.tags.create"))))
	h.await("the tag", func() bool {
		return strings.Contains(gitRun(t, dir, "tag", "--list"), "v1")
	})
	if got := gitRun(t, dir, "rev-parse", "v1^{commit}"); got != initial {
		t.Fatalf("the tag is on %s, want the clicked commit %s", got, initial)
	}
}

func TestLogCommitMenuOffersUndoAndSquashOnlyAsCoreHints(t *testing.T) {
	hints := core.HistoryActionCapabilities{CanUndo: true}
	cases := []struct {
		operation     string
		single, ready bool
		want          bool
	}{
		{core.HistoryUndoCommit, true, false, false},
		{core.HistoryUndoCommit, true, true, true},
		{core.HistorySquashCommits, false, true, false},
		{core.HistoryEditCommitMessage, true, false, true},
		{core.HistoryEditCommitMessage, false, true, false},
		{core.HistoryDeleteCommit, true, true, true},
	}
	for _, tc := range cases {
		if got := historyRewriteFits(tc.operation, tc.single, tc.ready, hints); got != tc.want {
			t.Errorf("historyRewriteFits(%s, single %v, ready %v) = %v, want %v", tc.operation, tc.single, tc.ready, got, tc.want)
		}
	}
}
