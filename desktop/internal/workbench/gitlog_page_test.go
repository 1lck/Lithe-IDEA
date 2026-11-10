package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// openLog opens dir with the log tab of the Git tool window shown and waits for its history.
func (h *harness) openLog(t *testing.T, dir string) *project {
	t.Helper()
	h.app.delays = logDelays{}
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	h.app.layout.gitTab = 0
	h.settle()
	if !p.log.started {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	return p
}

func TestLogCommitListSelectsWithTheKeyboard(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	rows := p.log.graph.Rows
	if len(rows) != 2 {
		t.Fatalf("the log has %d rows, want 2", len(rows))
	}

	h.clickNamed("second")
	h.settle()
	if p.log.selected != rows[0].CommitHash {
		t.Fatalf("selected %q after the click, want the newest commit %q", p.log.selected, rows[0].CommitHash)
	}
	if err := h.driver.Key(gfx.KeyDown, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if p.log.selected != rows[1].CommitHash {
		t.Fatalf("selected %q after Down, want the older commit %q", p.log.selected, rows[1].CommitHash)
	}
}

func TestLogDateChipFiltersThroughItsPopover(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	g := h.app.text.Git

	h.clickNamed(g.FilterDate)
	if p.log.popover != logPopoverDate {
		t.Fatalf("popover %v after clicking the date chip, want the date filter", p.log.popover)
	}
	if !h.shows(g.Last7Days) {
		t.Fatalf("the date popover does not list %q", g.Last7Days)
	}
	h.clickNamed(g.Last7Days)
	h.settle()
	if p.log.date != logLast7Days || p.log.popover != logPopoverNone {
		t.Fatalf("date %v popover %v after choosing %q", p.log.date, p.log.popover, g.Last7Days)
	}
}

func TestLogMenuOpensTheFetchOptionsDialogAndEscapeClosesIt(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	g := h.app.text.Git

	h.clickNamed(g.Actions)
	if p.log.popover != logPopoverMenu {
		t.Fatalf("popover %v after clicking the menu button, want the menu", p.log.popover)
	}
	h.clickNamed(g.FetchOptions)
	h.settle()
	if p.log.sync.dialog != syncDialogFetch {
		t.Fatalf("sync dialog %v, want the fetch options", p.log.sync.dialog)
	}
	if !h.shows(h.app.text.Sync.FetchTitle) {
		t.Fatalf("the dialog does not show its title %q", h.app.text.Sync.FetchTitle)
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if p.log.sync.dialog != syncDialogNone {
		t.Fatalf("sync dialog %v after Escape, want none", p.log.sync.dialog)
	}
}

func TestBranchDialogClosesOnEscape(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.openBranches(dir)
	h.clickNamed(h.app.text.Branch.NewBranch)
	if h.app.branch.dialog != branchDialogCreate {
		t.Fatalf("dialog %v, want the create dialog", h.app.branch.dialog)
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.branch.dialog != branchDialogNone {
		t.Fatalf("dialog %v after Escape, want none", h.app.branch.dialog)
	}
}
