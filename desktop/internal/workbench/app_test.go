package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// testKernel answers the layout and recent project reducers with the real kernel and Git
// status with the answer the test chose.
type testKernel struct {
	*core.Client
	status        core.GitStatus
	chromeActions []core.ChromeAction
}

func (k *testKernel) GitStatus(context.Context, string) (core.GitStatus, error) {
	return k.status, nil
}

func (k *testKernel) ReduceChromeLayout(ctx context.Context, catalog []core.ChromeItem, state core.ChromeLayout, action core.ChromeAction) (core.ChromeLayout, bool, error) {
	k.chromeActions = append(k.chromeActions, action)
	return k.Client.ReduceChromeLayout(ctx, catalog, state, action)
}

// harness is a window driven without a screen.
type harness struct {
	t   testing.TB
	app *App
	// config is the configuration the driver runs, so a test reads the callbacks the
	// window was opened with instead of building a second configuration.
	config app.Config
	driver *app.Driver
	store  *store.Store
}

// A test replacing the shared native watch must release its existing owner.
func replaceSearchWatchForTest(p *project, slot *documentWatch) {
	if p.search.watch != nil && p.search.watch != slot {
		p.search.watch.close()
	}
	p.search.watch = slot
}

// newHarness makes a Chinese window over a fresh store and paints its first frame. The
// window's clock is the driver's virtual time, so the frame counter never depends on how
// fast the test runs.
func newHarness(t testing.TB, kernel Kernel) *harness {
	return newHarnessWithLanguages(t, kernel, []string{"zh-Hans"})
}

// newHarnessWithLanguages makes a window whose language is chosen by the test and paints
// its first frame without opening a native window.
func newHarnessWithLanguages(t testing.TB, kernel Kernel, languages []string) *harness {
	t.Helper()
	dir := t.TempDir()
	// An explicit theme keeps New from asking the system for its appearance, which
	// blocks when no application is running.
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return newHarnessWithOptions(t, Options{
		Kernel:    kernel,
		Store:     store.At(dir),
		Languages: languages,
	})
}

// newHarnessWithOptions makes a window from explicit options. The caller owns
// the store and plugin root; the options' Now is replaced with the driver's
// virtual clock so frame counters stay deterministic.
func newHarnessWithOptions(t testing.TB, options Options) *harness {
	t.Helper()
	h := &harness{t: t, store: options.Store}
	start := time.Unix(1_700_000_000, 0)
	options.Now = func() time.Time {
		if h.driver == nil {
			return start
		}
		return start.Add(h.driver.Now())
	}
	h.app = New(options)
	h.config = h.app.Config()
	driver, err := app.NewDriver(h.config, nil)
	if err != nil {
		t.Fatalf("NewDriver: %v", err)
	}
	h.driver = driver
	t.Cleanup(func() {
		h.app.closeProject()
		deadline := time.NewTimer(8 * time.Second)
		defer deadline.Stop()
		for h.app.project != nil && h.app.closingProject {
			select {
			case <-driver.Wakes():
				if err := driver.Pump(); err != nil {
					t.Errorf("cleanup pump: %v", err)
					goto dispose
				}
			case <-deadline.C:
				t.Error("project cleanup did not finish before its deadline")
				goto dispose
			}
		}
	dispose:
		// A test that fails while a real language server is running still owns
		// the serve loops; cancel them before waiting for every task.
		h.app.stopAllPluginServers()
		if p := h.app.project; p != nil {
			p.cancel()
			h.app.closeTree(p)
			h.app.releaseProjectSearch(p)
			h.app.closeDocuments(p)
			h.app.closeTerminals(p)
			h.app.project = nil
		}
		h.app.wait()
		driver.Close()
	})
	return h
}

// settle lets every background task finish and paints their results.
func (h *harness) settle() {
	h.t.Helper()
	h.app.wait()
	if err := h.driver.Pump(); err != nil {
		h.t.Fatalf("Pump: %v", err)
	}
}

// open opens dir as the project and paints the workbench with its Git answer.
func (h *harness) open(dir string) {
	h.t.Helper()
	h.app.openProject(dir)
	h.settle()
}

// shows reports whether a label in the current frame contains value.
func (h *harness) shows(value string) bool {
	for _, label := range h.driver.Snapshot().Labels {
		if strings.Contains(label.Value, value) {
			return true
		}
	}
	// An assistant reply is painted by Viva's Markdown view, which records no labels. Its
	// message gets a view only when its row is declared, so this keeps the virtual window
	// meaningful: a row that was never declared has none.
	if p := h.app.project; p != nil {
		for _, m := range p.agent.messages {
			if m.md != nil && m.md.parsed > 0 && strings.Contains(m.Text, value) {
				return true
			}
		}
	}
	return false
}

// button is where catalog item id was laid out in the last frame.
func (h *harness) button(id string) gfx.Rect {
	h.t.Helper()
	rect := h.app.chrome.rects[h.app.chrome.index[id]]
	if rect.Width == 0 || rect.Height == 0 {
		h.t.Fatalf("button %s is not shown", id)
	}
	return rect
}

// drag presses at from, moves to to in steps and releases there.
func (h *harness) drag(from, to gfx.Point) {
	h.t.Helper()
	steps := []error{h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary)}
	for i := 1; i <= 4; i++ {
		f := float32(i) / 4
		steps = append(steps, h.driver.Move(from.X+(to.X-from.X)*f, from.Y+(to.Y-from.Y)*f))
	}
	steps = append(steps, h.driver.Release(to.X, to.Y, gfx.PointerButtonPrimary))
	for _, err := range steps {
		if err != nil {
			h.t.Fatalf("drag: %v", err)
		}
	}
}

func center(r gfx.Rect) gfx.Point { return gfx.Point{X: r.X + r.Width/2, Y: r.Y + r.Height/2} }

// zoneItems is the ids of the buttons in z, in display order.
func (h *harness) zoneItems(z zone) []string {
	var ids []string
	for _, index := range h.app.chrome.items[z] {
		ids = append(ids, h.app.chrome.catalog[index].id)
	}
	return ids
}

func TestWorkbenchDefaultLayout(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient(), status: core.GitStatus{
		RepositoryRoot: ".", Branch: "preview",
		Changes: []core.GitChange{{Path: "a.go", Status: "M"}, {Path: "b.go", Status: "M"}},
	}})
	h.open(t.TempDir())

	// The split zones above the bottom groups start empty: the buttons at the end of each
	// stripe open in the bottom area instead.
	want := map[zone][]string{
		zoneLeftTop:     {itemProject, itemCommit, itemStructure, itemFind},
		zoneLeftBottom:  nil,
		zoneBottomLeft:  {itemGit, itemTerminal, itemProblems, itemReferences, itemRun, itemTests, itemSecurity, itemDebug},
		zoneRightTop:    {itemNotifications, itemMarkdown, itemAssistant},
		zoneRightBottom: nil,
		zoneBottomRight: {itemUpdates, itemBackground},
		zoneTitle:       {itemRunConfig, itemTitleRun, itemTitleDebug, itemTitleSearch, itemTitleSettings},
		zoneStatus:      {itemCaret, itemLock, itemEncoding, itemLSP, itemMemory, itemFPS, itemChanges, itemHealth},
	}
	for z, ids := range want {
		if got := h.zoneItems(z); strings.Join(got, ",") != strings.Join(ids, ",") {
			t.Errorf("zone %d = %v, want %v", z, got, ids)
		}
		for _, id := range ids {
			h.button(id)
		}
	}
	if !h.app.chrome.isOpen(catalogIndex[itemProject]) || !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		t.Errorf("open tool windows = %v, want the project and Git windows", h.app.chrome.open)
	}
	for _, text := range []string{"preview", "2 个更改", "LSP 未启动", "日志", "工作树", "控制台"} {
		if !h.shows(text) {
			t.Errorf("the workbench does not show %q", text)
		}
	}
}

func TestDragToolButtonToAnotherStripeZone(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	target := h.app.chrome.zoneRects[zoneBottomRight]
	if target.Height == 0 {
		t.Fatal("the right stripe's bottom zone is not shown")
	}
	h.drag(center(h.button(itemCommit)), gfx.Point{X: target.X + target.Width/2, Y: target.Y + target.Height - 2})
	h.settle()

	if got := h.zoneItems(zoneBottomRight); strings.Join(got, ",") != strings.Join([]string{itemUpdates, itemBackground, itemCommit}, ",") {
		t.Fatalf("bottom right zone = %v, want the commit button appended", got)
	}
	if got := h.zoneItems(zoneLeftTop); strings.Contains(strings.Join(got, ","), itemCommit) {
		t.Fatalf("left top zone = %v still holds the commit button", got)
	}

	var saved core.ChromeLayout
	if found, err := h.store.Load(layoutFile, &saved); err != nil || !found {
		t.Fatalf("saved layout found = %v, err = %v, want it saved", found, err)
	}
	reopened := newHarness(t, &testKernel{Client: core.NewClient()})
	reopened.app.store = h.store
	reopened.app.loadChrome()
	if got := reopened.app.chrome.zoneOf(catalogIndex[itemCommit]); got != zoneBottomRight {
		t.Fatalf("after reloading the commit button is in zone %d, want the bottom right zone", got)
	}
}

// TestDragToolButtonToEmptySplitZone drags a button into the split group near the bottom
// of the left stripe. That zone is empty and takes no room at rest, so it only exists as
// a place to drop while a tool button is being dragged.
func TestDragToolButtonToEmptySplitZone(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	if r := h.app.chrome.zoneRects[zoneLeftBottom]; r.Height != 0 {
		t.Fatalf("the empty left bottom zone is %v high at rest, want it to take no room", r.Height)
	}
	from := center(h.button(itemCommit))
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("drag: %v", err)
		}
	}
	must(h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary))
	must(h.driver.Move(from.X, from.Y+2*dragThreshold))

	target := h.app.chrome.zoneRects[zoneLeftBottom]
	if target.Height < chromeToolButton {
		t.Fatalf("the empty left bottom zone is %v high during the drag, want at least a button", target.Height)
	}
	to := center(target)
	must(h.driver.Move(to.X, to.Y))
	must(h.driver.Release(to.X, to.Y, gfx.PointerButtonPrimary))
	h.settle()

	if got := h.zoneItems(zoneLeftBottom); strings.Join(got, ",") != itemCommit {
		t.Fatalf("left bottom zone = %v, want only the commit button", got)
	}
	if r := h.app.chrome.zoneRects[zoneLeftBottom]; r.Height < chromeToolButton {
		t.Fatalf("the left bottom zone is %v high with a button in it, want at least a button", r.Height)
	}
}

func TestStripeZonesKeepTheSplitGroupAboveTheBottomGroup(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	from := center(h.button(itemCommit))
	if err := h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Move(from.X, from.Y+2*dragThreshold); err != nil {
		t.Fatal(err)
	}
	h.settle()

	stripes := dragStripeRects(gfx.Rect{Width: float32(h.driver.Snapshot().Width), Height: float32(h.driver.Snapshot().Height)})
	cases := []struct {
		name            string
		side            stripeSide
		top, split, end zone
	}{
		{name: "left", side: stripeLeft, top: zoneLeftTop, split: zoneLeftBottom, end: zoneBottomLeft},
		{name: "right", side: stripeRight, top: zoneRightTop, split: zoneRightBottom, end: zoneBottomRight},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stripe := stripes[tc.side]
			top := h.app.chrome.zoneRects[tc.top]
			split := h.app.chrome.zoneRects[tc.split]
			end := h.app.chrome.zoneRects[tc.end]
			topBottom := top.Y + top.Height
			if topBottom >= split.Y {
				t.Fatalf("%s split group starts at %v after the top group ends at %v, want flexible space between them", tc.name, split.Y, topBottom)
			}
			if split.Height < chromeToolButton || end.Height < chromeToolButton {
				t.Fatalf("%s split and bottom groups are %v and %v high during a drag, want at least one button each", tc.name, split.Height, end.Height)
			}
			if split.Y+split.Height != end.Y {
				t.Fatalf("%s split group ends at %v and bottom group starts at %v, want them adjacent", tc.name, split.Y+split.Height, end.Y)
			}
			if end.Y+end.Height > stripe.Y+stripe.Height {
				t.Fatalf("%s bottom group ends at %v beyond the stripe end %v", tc.name, end.Y+end.Height, stripe.Y+stripe.Height)
			}
			for _, primitive := range h.driver.Snapshot().Primitives {
				bounds := primitive.Bounds
				if bounds.Height == 1 && bounds.Width > 1 && bounds.X >= stripe.X && bounds.X+bounds.Width <= stripe.X+stripe.Width && bounds.Y >= topBottom && bounds.Y <= split.Y {
					t.Errorf("%s stripe has a horizontal separator at %v in the flexible space", tc.name, bounds)
				}
			}
		})
	}
	h.app.dnd.tool.Cancel()
}

func TestSnappedStripeDragReordersAndLocksTheGhostToItsColumn(t *testing.T) {
	kernel := &testKernel{Client: core.NewClient()}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	kernel.chromeActions = nil

	from := center(h.button(itemAssistant))
	targetButton := h.button(itemNotifications)
	to := gfx.Point{X: from.X, Y: targetButton.Y + dragThreshold}
	if err := h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Move(to.X, to.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()

	if h.app.drag.phase != dragSnapped || h.app.drag.snappedStripe != stripeRight {
		t.Fatalf("drag phase and stripe = %v and %v, want snapped on the right", h.app.drag.phase, h.app.drag.snappedStripe)
	}
	if !h.app.drag.hasTarget || h.app.drag.target.zone != zoneRightTop || h.app.drag.target.before != itemNotifications {
		t.Fatalf("snapped target = %+v, has target %v; want right top before %q", h.app.drag.target, h.app.drag.hasTarget, itemNotifications)
	}
	column := h.app.chrome.zoneRects[zoneRightTop]
	wantX := column.X + (column.Width-dragSnappedGhostSize)/2
	foundGhost := false
	for _, primitive := range h.driver.Snapshot().Primitives {
		bounds := primitive.Bounds
		if primitive.Layer == dragLayer && bounds.Width == dragSnappedGhostSize && bounds.Height == dragSnappedGhostSize && primitive.Color == h.app.colors.Accent {
			foundGhost = true
			if bounds.X != wantX {
				t.Errorf("snapped ghost x = %v, want button-column x %v", bounds.X, wantX)
			}
		}
	}
	if !foundGhost {
		t.Fatal("the snapped drag has no 32 by 32 accent-bordered ghost on the drag layer")
	}

	if err := h.driver.Release(to.X, to.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	h.settle()
	wantAction := core.MoveChrome(itemAssistant, core.ZoneRightTop, itemNotifications)
	if len(kernel.chromeActions) != 1 || kernel.chromeActions[0] != wantAction {
		t.Fatalf("chrome actions = %v, want one MoveChrome to right top before %q", kernel.chromeActions, itemNotifications)
	}
}

func TestDetachedStripeDragTargetsDockAreasAndOtherStripeButtons(t *testing.T) {
	cases := []struct {
		name   string
		point  func(*harness) gfx.Point
		zone   zone
		before string
	}{
		{
			name: "right lower half",
			point: func(h *harness) gfx.Point {
				area := h.app.dragDockAnchors(gfx.Size{Width: 1280, Height: 800})[dockAnchorRight].area
				return gfx.Point{X: area.X + area.Width/2, Y: area.Y + 3*area.Height/4}
			},
			zone: zoneRightBottom,
		},
		{
			name: "bottom right half",
			point: func(h *harness) gfx.Point {
				area := h.app.dragDockAnchors(gfx.Size{Width: 1280, Height: 800})[dockAnchorBottom].area
				return gfx.Point{X: area.X + 3*area.Width/4, Y: h.button(itemUpdates).Y + dragThreshold}
			},
			zone: zoneBottomRight, before: itemUpdates,
		},
		{
			name: "upper left area",
			point: func(h *harness) gfx.Point {
				area := h.app.dragDockAnchors(gfx.Size{Width: 1280, Height: 800})[dockAnchorLeft].area
				return gfx.Point{X: area.X + area.Width/2, Y: area.Y + dragMarkLead}
			},
			zone: zoneLeftTop, before: itemProject,
		},
		{
			name: "other stripe button",
			point: func(h *harness) gfx.Point {
				button := h.button(itemCommit)
				return gfx.Point{X: button.X + button.Width/2, Y: button.Y + dragThreshold}
			},
			zone: zoneLeftTop, before: itemCommit,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kernel := &testKernel{Client: core.NewClient()}
			h := newHarness(t, kernel)
			h.open(t.TempDir())
			kernel.chromeActions = nil

			from := center(h.button(itemAssistant))
			stripes := dragStripeRects(gfx.Rect{Width: 1280, Height: 800})
			detached := gfx.Point{X: stripes[stripeRight].X - dragDetachDistance - 1, Y: from.Y}
			if err := h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary); err != nil {
				t.Fatal(err)
			}
			if err := h.driver.Move(detached.X, detached.Y); err != nil {
				t.Fatal(err)
			}
			if h.app.drag.phase != dragDetached {
				t.Fatalf("phase after pulling past the right stripe = %v, want detached", h.app.drag.phase)
			}

			to := tc.point(h)
			if err := h.driver.Move(to.X, to.Y); err != nil {
				t.Fatal(err)
			}
			if err := h.driver.Release(to.X, to.Y, gfx.PointerButtonPrimary); err != nil {
				t.Fatal(err)
			}
			h.settle()

			wantAction := core.MoveChrome(itemAssistant, zoneNames[tc.zone], tc.before)
			if len(kernel.chromeActions) != 1 || kernel.chromeActions[0] != wantAction {
				t.Fatalf("chrome actions = %v, want one MoveChrome to zone %d before %q", kernel.chromeActions, tc.zone, tc.before)
			}
			if got := h.app.chrome.zoneOf(catalogIndex[itemAssistant]); got != tc.zone {
				t.Fatalf("assistant is in zone %d after release, want zone %d", got, tc.zone)
			}
		})
	}
}

func TestDetachedStripeDragWithoutATargetDoesNotCommit(t *testing.T) {
	kernel := &testKernel{Client: core.NewClient()}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	kernel.chromeActions = nil

	from := center(h.button(itemAssistant))
	stripes := dragStripeRects(gfx.Rect{Width: 1280, Height: 800})
	detached := gfx.Point{X: stripes[stripeRight].X - dragDetachDistance - 1, Y: from.Y}
	main := h.app.layout.mainRect
	noTarget := gfx.Point{X: main.X + main.Width/2, Y: main.Y + main.Height/4}
	if err := h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Move(detached.X, detached.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Move(noTarget.X, noTarget.Y); err != nil {
		t.Fatal(err)
	}
	if h.app.drag.phase != dragDetached || h.app.drag.hasTarget {
		t.Fatalf("phase and target at the editor center = %v and %v, want detached without a target", h.app.drag.phase, h.app.drag.hasTarget)
	}
	if err := h.driver.Release(noTarget.X, noTarget.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	h.settle()

	if len(kernel.chromeActions) != 0 {
		t.Fatalf("chrome actions = %v, want no committed move", kernel.chromeActions)
	}
	if got := h.app.chrome.zoneOf(catalogIndex[itemAssistant]); got != zoneRightTop {
		t.Fatalf("assistant is in zone %d after a targetless release, want the source zone", got)
	}
}

func TestDetachedDropPreviewUsesTheLocalizedDockTitle(t *testing.T) {
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		t.Run(language.Code(), func(t *testing.T) {
			h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{language.Code()})
			h.open(t.TempDir())
			from := center(h.button(itemAssistant))
			stripes := dragStripeRects(gfx.Rect{Width: 1280, Height: 800})
			detached := gfx.Point{X: stripes[stripeRight].X - dragDetachDistance - 1, Y: from.Y}
			area := h.app.dragDockAnchors(gfx.Size{Width: 1280, Height: 800})[dockAnchorRight].area
			to := gfx.Point{X: area.X + area.Width/2, Y: area.Y + 3*area.Height/4}
			if err := h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary); err != nil {
				t.Fatal(err)
			}
			if err := h.driver.Move(detached.X, detached.Y); err != nil {
				t.Fatal(err)
			}
			if err := h.driver.Move(to.X, to.Y); err != nil {
				t.Fatal(err)
			}
			h.settle()

			if !h.app.drag.hasTarget || h.app.drag.phase != dragDetached || h.app.drag.target.zone != zoneRightBottom {
				t.Fatalf("detached target = %+v, phase %v, has target %v; want the right bottom dock zone", h.app.drag.target, h.app.drag.phase, h.app.drag.hasTarget)
			}
			wantTitle := h.app.text.Dock.MoveRightBottom
			found := false
			for _, label := range h.driver.Snapshot().Labels {
				if label.Value == wantTitle {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("detached preview does not show the exact %s title %q", language.Code(), wantTitle)
			}
			h.app.dnd.tool.Cancel()
		})
	}
}

// closedSlots is the open tool windows of a workbench with none open.
func closedSlots() [slotCount]int {
	var open [slotCount]int
	for i := range open {
		open[i] = -1
	}
	return open
}

// TestShellColumnsSplitWhenBothTheirSlotsAreOpen checks the division of the main column:
// a column takes its width for either slot, and shows both tool windows one over the
// other, the lower one at its chosen height, when both are open.
func TestShellColumnsSplitWhenBothTheirSlotsAreOpen(t *testing.T) {
	window := gfx.Rect{Width: 1400, Height: 900}

	t.Run("one slot takes the whole column", func(t *testing.T) {
		for _, s := range []slot{slotLeftTop, slotLeftBottom} {
			l := newLayoutState()
			open := closedSlots()
			open[s] = catalogIndex[itemProject]
			p := l.arrange(window, open)
			if !p.left() || p.leftSplit() || p.right() || p.bottom() {
				t.Errorf("slot %d open: left=%v split=%v right=%v bottom=%v, want only an unsplit left column", s, p.left(), p.leftSplit(), p.right(), p.bottom())
			}
			if p.leftW != shellLeftDefault {
				t.Errorf("slot %d open: left column is %v wide, want %v", s, p.leftW, float32(shellLeftDefault))
			}
		}
		for _, s := range []slot{slotRightTop, slotRightBottom} {
			l := newLayoutState()
			open := closedSlots()
			open[s] = catalogIndex[itemNotifications]
			p := l.arrange(window, open)
			if !p.right() || p.rightSplit() || p.left() || p.bottom() {
				t.Errorf("slot %d open: right=%v split=%v left=%v bottom=%v, want only an unsplit right column", s, p.right(), p.rightSplit(), p.left(), p.bottom())
			}
			if p.rightW != shellRightDefault {
				t.Errorf("slot %d open: right column is %v wide, want %v", s, p.rightW, float32(shellRightDefault))
			}
		}
	})

	t.Run("both slots stack the tool windows", func(t *testing.T) {
		l := newLayoutState()
		open := closedSlots()
		open[slotLeftTop], open[slotLeftBottom] = catalogIndex[itemProject], catalogIndex[itemCommit]
		open[slotRightTop], open[slotRightBottom] = catalogIndex[itemNotifications], catalogIndex[itemUpdates]
		open[slotBottomLeft] = catalogIndex[itemGit]
		p := l.arrange(window, open)

		if !p.leftSplit() || !p.rightSplit() {
			t.Fatalf("split = left %v right %v, want both columns split", p.leftSplit(), p.rightSplit())
		}
		if p.leftLowerH != shellColumnLowerDefault || p.rightLowerH != shellColumnLowerDefault {
			t.Errorf("lower heights = %v and %v, want %v", p.leftLowerH, p.rightLowerH, float32(shellColumnLowerDefault))
		}
		if p.leftUpperH+shellSplitter+p.leftLowerH != p.topH || p.rightUpperH+shellSplitter+p.rightLowerH != p.topH {
			t.Errorf("the halves of a column and its splitter are %v and %v high, want the top row's %v",
				p.leftUpperH+shellSplitter+p.leftLowerH, p.rightUpperH+shellSplitter+p.rightLowerH, p.topH)
		}
		// A splitter is declared at the size of the pane before it.
		if got := l.split[shellSplitLeftColumn].Pos; got != p.leftUpperH {
			t.Errorf("left column splitter at %v, want the upper tool window's %v", got, p.leftUpperH)
		}
		if got := l.split[shellSplitRightColumn].Pos; got != p.rightUpperH {
			t.Errorf("right column splitter at %v, want the upper tool window's %v", got, p.rightUpperH)
		}
	})

	t.Run("the lower height is limited but not forgotten", func(t *testing.T) {
		l := newLayoutState()
		open := closedSlots()
		open[slotLeftTop], open[slotLeftBottom] = catalogIndex[itemProject], catalogIndex[itemCommit]

		l.leftLower = 10000
		p := l.arrange(window, open)
		if p.leftUpperH != shellPanelHeightMin || p.leftLowerH != p.topH-shellSplitter-shellPanelHeightMin {
			t.Errorf("a huge lower height gave %v over %v, want the upper window at its least", p.leftUpperH, p.leftLowerH)
		}
		l.leftLower = 10
		p = l.arrange(window, open)
		if p.leftLowerH != shellPanelHeightMin {
			t.Errorf("a tiny lower height gave %v, want the least %v", p.leftLowerH, float32(shellPanelHeightMin))
		}
		if l.leftLower != 10 {
			t.Errorf("the chosen lower height became %v, want the limit never to be written back", l.leftLower)
		}
	})

	t.Run("a split column keeps the top row tall enough", func(t *testing.T) {
		l := newLayoutState()
		open := closedSlots()
		open[slotBottomLeft] = catalogIndex[itemGit]
		l.bottom = 10000
		if p := l.arrange(window, open); p.topH != shellEditorHeightMin {
			t.Errorf("top row = %v high without a split column, want the editor's least %v", p.topH, float32(shellEditorHeightMin))
		}

		open[slotLeftTop], open[slotLeftBottom] = catalogIndex[itemProject], catalogIndex[itemCommit]
		p := l.arrange(window, open)
		const want = 2*shellPanelHeightMin + shellSplitter
		if p.topH != want || p.leftUpperH != shellPanelHeightMin || p.leftLowerH != shellPanelHeightMin {
			t.Errorf("top row = %v with halves %v and %v, want %v with both at their least", p.topH, p.leftUpperH, p.leftLowerH, float32(want))
		}
	})

	t.Run("dragging the splitter chooses the lower height", func(t *testing.T) {
		l := newLayoutState()
		open := closedSlots()
		open[slotLeftTop], open[slotLeftBottom] = catalogIndex[itemProject], catalogIndex[itemCommit]
		open[slotRightTop], open[slotRightBottom] = catalogIndex[itemNotifications], catalogIndex[itemUpdates]
		p := l.arrange(window, open)

		l.split[shellSplitLeftColumn].Pos = p.leftUpperH + 100
		l.adopt(shellSplitLeftColumn)
		l.split[shellSplitRightColumn].Pos = p.rightUpperH - 50
		l.adopt(shellSplitRightColumn)

		if want := p.leftLowerH - 100; l.leftLower != want {
			t.Errorf("left lower height = %v after moving the splitter down 100, want %v", l.leftLower, want)
		}
		if want := p.rightLowerH + 50; l.rightLower != want {
			t.Errorf("right lower height = %v after moving the splitter up 50, want %v", l.rightLower, want)
		}
	})
}

func TestDragTitleItemReorders(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	first := h.button(itemRunConfig)
	h.drag(center(h.button(itemTitleSettings)), gfx.Point{X: first.X + 2, Y: first.Y + first.Height/2})
	h.settle()

	got := h.zoneItems(zoneTitle)
	if len(got) == 0 || got[0] != itemTitleSettings {
		t.Fatalf("title bar = %v, want the settings button first", got)
	}
}

func TestStatusItemCannotLeaveTheStatusBar(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	stripe := h.app.chrome.zoneRects[zoneLeftTop]
	h.drag(center(h.button(itemMemory)), center(stripe))
	h.settle()

	if got := h.app.chrome.zoneOf(catalogIndex[itemMemory]); got != zoneStatus {
		t.Fatalf("the memory readout moved to zone %d, want it to stay in the status bar", got)
	}
}

func TestResetLayoutRestoresDefaults(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.app.reduceChrome(core.MoveChrome(itemProject, core.ZoneRightTop, ""))
	if h.app.chrome.zoneOf(catalogIndex[itemProject]) != zoneRightTop {
		t.Fatal("moving the project button through the kernel did not take effect")
	}

	h.app.resetLayout()

	if got := h.app.chrome.zoneOf(catalogIndex[itemProject]); got != zoneLeftTop {
		t.Fatalf("after the reset the project button is in zone %d, want the left top zone", got)
	}
}

func TestClosingProjectReturnsToWelcome(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	dir := t.TempDir()
	h.open(dir)
	h.app.closeProject()
	h.settle()

	if h.app.project != nil {
		t.Fatal("the project is still open")
	}
	if len(h.app.recent) != 1 || h.app.recent[0].Path != dir {
		t.Fatalf("recent projects = %+v, want the closed project", h.app.recent)
	}
	if !h.shows(h.app.text.Welcome.Projects) {
		t.Fatal("the start screen is not shown after closing the project")
	}
}

// hit is where the hit id was laid out in the last frame.
func (h *harness) hit(id gfx.ID) gfx.Rect {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == id {
			return hit.Bounds
		}
	}
	h.t.Fatalf("hit %v is not shown", id)
	return gfx.Rect{}
}

func TestSettingsButtonOpensItsMenu(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	gear := center(h.button(itemTitleSettings))
	if err := h.driver.Click(gear.X, gear.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()

	if !h.app.title.gearOpen {
		t.Fatal("the settings button did not open its menu")
	}
	for _, label := range []string{h.app.text.Title.Preferences, h.app.text.Title.Plugins, h.app.text.Title.LogsAndDiagnostics, h.app.text.Title.ThemeMenu, h.app.text.Title.Keymap} {
		if !h.shows(label) {
			t.Fatalf("the settings menu does not show %q", label)
		}
	}

	// The window was made without a log, so asking for the log window says so.
	logs := center(h.hitLabeled(h.app.text.Title.LogsAndDiagnostics))
	if err := h.driver.Click(logs.X, logs.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.title.gearOpen {
		t.Fatal("the menu stayed open after an item was chosen")
	}
	if h.app.notice != h.app.text.Title.LogsUnavailable {
		t.Fatalf("notice = %q, want the log is unavailable", h.app.notice)
	}
	h.app.notice = ""

	if err := h.driver.Click(gear.X, gear.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	settings := center(h.hitLabeled(h.app.text.Title.Preferences))
	if err := h.driver.Click(settings.X, settings.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	// The settings open in a window of their own, which a window made without an application
	// cannot open; choosing the item closes the menu and reports nothing.
	if h.app.title.gearOpen {
		t.Fatal("the menu stayed open after Settings… was chosen")
	}
	if h.app.notice != "" {
		t.Fatalf("notice = %q, want none", h.app.notice)
	}
}

func TestMarketplaceWidthPersistsWithOtherSettings(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.setLanguage("zh-Hans")
	h.app.setMarketplaceWidth(420)
	var saved settings
	found, err := h.store.Load(settingsFile, &saved)
	if err != nil || !found {
		t.Fatalf("load saved settings: found=%v err=%v", found, err)
	}
	if saved.MarketplaceWidth != 420 || saved.Language != "zh-Hans" || saved.Theme != themeDark {
		t.Fatalf("saved settings lost values: %+v", saved)
	}
}

// TestWindowControlsFollowTheTitleBar covers the buttons Viva draws in the custom title bar on
// Windows and Linux: unstyled, they took Viva's ink for its default dark clear color and were
// white on the light title bar. They must take the ink of the title bar and the language of
// the window, and follow both when they change.
func TestWindowControlsFollowTheTitleBar(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	if h.config.WindowControls == nil {
		t.Fatal("the workbench leaves its window buttons to Viva's default ink")
	}
	check := func(look string, ink gfx.Color, minimize string) {
		t.Helper()
		style := h.config.WindowControls()
		if style.Foreground != ink || style.Minimize != minimize {
			t.Fatalf("%s look: glyph color %v and minimize name %q, want %v and %q", look, style.Foreground, style.Minimize, ink, minimize)
		}
	}
	_, darkColors := darkLook()
	check("dark", darkColors.Text, "最小化")
	h.app.setLanguage("en")
	h.app.setTheme(themeLight)
	_, lightColors := lightLook()
	check("light", lightColors.Text, "Minimize")
}

func TestSettingsChangesUpdateSharedStateAndPersist(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.setLanguage("en")
	h.app.setTheme(themeLight)
	if h.app.shared.text.Load() != i18n.For(i18n.English) || h.app.shared.dark.Load() {
		t.Fatal("shared window state did not reflect the selected language and appearance")
	}
	var saved settings
	found, err := h.store.Load(settingsFile, &saved)
	if err != nil || !found || saved.Language != "en" || saved.Theme != themeLight {
		t.Fatalf("persisted settings = %+v, found=%v err=%v", saved, found, err)
	}
}

func TestSystemAppearanceChangesSharedStateWhenFollowingSystem(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.setTheme(themeSystem)
	h.driver.SetSystemAppearance(app.AppearanceDark)
	h.app.systemAppearanceChanged()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if !h.app.shared.dark.Load() {
		t.Fatal("shared appearance did not follow the system")
	}
	h.app.setTheme(themeLight)
	h.driver.SetSystemAppearance(app.AppearanceLight)
	h.driver.SetSystemAppearance(app.AppearanceDark)
	h.app.systemAppearanceChanged()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if h.app.shared.dark.Load() {
		t.Fatal("system appearance overrode the explicit light setting")
	}
}

// hitLabeled is where the control named label was laid out in the last frame.
func (h *harness) hitLabeled(label string) gfx.Rect {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel {
			return hit.Bounds
		}
	}
	h.t.Fatalf("no control named %q is shown", label)
	return gfx.Rect{}
}

// dragThreshold is how far a press moves before Viva takes it for a drag.
const dragThreshold = 4
