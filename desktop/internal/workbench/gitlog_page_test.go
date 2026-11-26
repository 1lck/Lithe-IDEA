package workbench

import (
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

func TestLogEllipsisShowsFullSubjectAndKeepsSelection(t *testing.T) {
	dir := newTestRepository(t)
	full := strings.Repeat("完整提交说明-long-subject-", 10) + "end"
	gitRun(t, dir, "commit", "--allow-empty", "-m", full)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	var text gfx.Rect
	for _, label := range h.driver.Snapshot().Labels {
		if strings.HasPrefix(label.Value, "完整提交") && strings.HasSuffix(label.Value, "…") {
			text = label.Bounds
			break
		}
	}
	if text.Width == 0 {
		t.Fatal("the commit subject was not ellipsized")
	}
	x, y := text.X+5, text.Y+text.Height/2
	if err := h.driver.Move(x, y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	var tip strings.Builder
	for _, label := range h.tooltips() {
		tip.WriteString(label.Value)
	}
	if tip.String() != full {
		t.Fatalf("commit tooltip %q, want %q", tip.String(), full)
	}
	h.click(gfx.Point{X: x, Y: y})
	h.settle()
	if p.log.selected != p.log.graph.Rows[0].CommitHash {
		t.Fatal("the full-text hint intercepted commit selection")
	}
}

// openLog opens dir with the log tab of the Git tool window shown and waits for its history.
func (h *harness) openLog(t *testing.T, dir string) *project {
	t.Helper()
	h.app.delays = logDelays{}
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	h.app.layout.gitTab = gitTabLog
	h.settle()
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
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

// The filter bar shows every view button that fits beside the text filter at its least width and
// the filters, and, when not all of them fit, as many as fit with the overflow menu's button.
func TestLogViewFitKeepsTheButtonsThatFitBesideTheFilters(t *testing.T) {
	// The filter bar's fixed parts: its padding, the text filter and the gaps around the filters.
	const fixed = 2*logBarPad + logSearchMin + 3*logBarGap
	const slot = shellHideSize + logBarGap
	for _, tc := range []struct {
		name            string
		bar, filters    float32
		count, wantShow int
	}{
		{"a bar not laid out yet shows every button", 0, 300, logViewCount, logViewCount},
		{"a bar with room for every button", fixed + 300 + logViewCount*slot - logBarGap, 300, logViewCount, logViewCount},
		{"one button short moves two to make room for the menu", fixed + 300 + logViewCount*slot - logBarGap - 1, 300, logViewCount, logViewCount - 2},
		{"room for three buttons shows two and the menu", fixed + 300 + 3*slot - logBarGap, 300, logViewCount, 2},
		{"a bar narrower than its filters shows only the menu", 340, 300, logViewCount, 0},
	} {
		if got := logViewFit(tc.bar, tc.filters, tc.count); got != tc.wantShow {
			t.Errorf("%s: logViewFit(%v, %v, %d) = %d, want %d", tc.name, tc.bar, tc.filters, tc.count, got, tc.wantShow)
		}
	}
}

// A bar with every view button in its overflow menu gives the text filter the room the filters and
// the menu's button leave, between logSearchFloor and logSearchMin.
func TestLogSearchWidthGivesTheTextFilterTheRoomTheFiltersLeave(t *testing.T) {
	// The filter bar's fixed parts: its padding, the menu's button and the gaps around the filters.
	const fixed = 2*logBarPad + shellHideSize + 3*logBarGap
	for _, tc := range []struct {
		name         string
		bar, filters float32
		want         float32
	}{
		{"room for the whole field keeps it at its least width", fixed + 300 + 200, 300, logSearchMin},
		{"less room narrows the field to it", fixed + 300 + 90, 300, 90},
		{"no room stops at the floor", fixed + 300 + 10, 300, logSearchFloor},
	} {
		if got := logSearchWidth(tc.bar, tc.filters); got != tc.want {
			t.Errorf("%s: logSearchWidth(%v, %v) = %v, want %v", tc.name, tc.bar, tc.filters, got, tc.want)
		}
	}
}

// A commit list too narrow for the filter bar's view buttons keeps the filters whole, moves the
// last buttons into the bar's overflow menu, and the menu does what the button it stands for does.
func TestLogToolbarMovesTheViewButtonsItHasNoRoomForIntoItsMenu(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	v, g := &h.app.logView, h.app.text.Git
	more := i18n.Shared(h.app.language(), "git.log.toolbar.moreActions")
	if more == "" {
		t.Fatal("the overflow menu's button has no name in the desktop catalog")
	}
	if _, ok := h.findPageHit(more); ok {
		t.Fatalf("a filter bar %v wide shows the overflow menu though every view button fits", v.barWidth)
	}

	// Narrow the commit list to room for three view buttons, and half of one more, beside the
	// text filter at its least width and the filters: two buttons and the menu's.
	const slot = shellHideSize + logBarGap
	target := 2*logBarPad + logSearchMin + v.filtersWidth + 3*logBarGap + 3*slot - logBarGap + slot/2
	v.detailWidth += v.barWidth - target
	h.relayLogBar()
	if _, ok := h.findPageHit(more); !ok {
		t.Fatalf("a filter bar %v wide with filters %v wide shows no overflow menu", v.barWidth, v.filtersWidth)
	}
	for _, name := range []string{g.FilterPaths, g.CompareBranch, g.ShowDetails} {
		if _, ok := h.findPageHit(name); !ok {
			t.Fatalf("a filter bar %v wide with filters %v wide does not show %q", v.barWidth, v.filtersWidth, name)
		}
	}
	if _, ok := h.findPageHit(g.LongEdges); ok {
		t.Fatalf("a filter bar %v wide still shows the last view button %q", v.barWidth, g.LongEdges)
	}

	h.clickNamed(more)
	if p.log.popover != logPopoverViewMore {
		t.Fatalf("popover %v after clicking %q, want the overflow menu", p.log.popover, more)
	}
	h.clickNamed(g.LongEdges)
	h.settle()
	if !p.log.expanded || p.log.popover != logPopoverNone {
		t.Fatalf("long edges %v popover %v after choosing %q in the menu, want them shown and the menu closed", p.log.expanded, p.log.popover, g.LongEdges)
	}
}

// At the commit list's least width every view button is in the overflow menu and the text filter
// gives up room, no narrower than logSearchFloor, for the filters.
func TestLogToolbarNarrowsTheTextFilterOnceEveryViewButtonIsInItsMenu(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openLog(t, dir)
	v, g := &h.app.logView, h.app.text.Git

	v.detailWidth = 10_000 // the details take all but the commit list's least width
	h.relayLogBar()
	if _, ok := h.findPageHit(g.CompareBranch); ok {
		t.Fatalf("a filter bar %v wide with filters %v wide still shows %q", v.barWidth, v.filtersWidth, g.CompareBranch)
	}
	h.pageHit(i18n.Shared(h.app.language(), "git.log.toolbar.moreActions"))
	if width := h.pageHit(g.TextOrHash).Bounds.Width; width >= logSearchMin || width < logSearchFloor {
		t.Fatalf("the text filter of a filter bar %v wide is %v wide, want narrower than %v and no narrower than %v",
			v.barWidth, width, float32(logSearchMin), float32(logSearchFloor))
	}
}

// relayLogBar paints the window twice after the log's filter bar changed width: the first paint
// lays the bar out and measures it, the second lays out the view buttons by that measure. The
// headless driver paints only when woken, so the paint the measurement asks for is made here.
func (h *harness) relayLogBar() {
	h.t.Helper()
	for range 2 {
		h.app.post(func(*App) {})
		h.settle()
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
