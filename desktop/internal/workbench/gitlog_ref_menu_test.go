package workbench

import (
	"cmp"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// logWithTopicBranch opens a repository whose main is checked out and whose branch topic has one
// commit more, on its log.
func logWithTopicBranch(t *testing.T) (*harness, *project, string) {
	t.Helper()
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	gitRun(t, dir, "checkout", "-b", "topic")
	if err := os.WriteFile(filepath.Join(dir, "topic.txt"), []byte("topic\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", "topic.txt")
	gitRun(t, dir, "commit", "-m", "topic work")
	gitRun(t, dir, "checkout", "main")
	h := newHarness(t, gitKernel{core.NewClient()})
	return h, h.openLog(t, dir), dir
}

// logRefMenu right-clicks the row of the reference pane that shows the reference named short.
func (h *harness) logRefMenu(short string) {
	h.t.Helper()
	v := &h.app.logView
	i := slices.IndexFunc(v.refItems, func(r logRefRow) bool { return r.kind == logRefReference && r.short == short })
	if i < 0 {
		h.t.Fatalf("the reference pane shows no row of %q", short)
	}
	point := center(h.topHit(v.refs.RowID(i)))
	if err := h.driver.ClickButton(point.X, point.Y, gfx.PointerButtonSecondary); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
	if item := h.app.text.Branch.NewBranchFrom(short); !h.hasPopupItem(item) {
		h.t.Fatalf("no menu item %q is shown after the right-click on %q", item, short)
	}
}

// topMenuItems lists the deepest open submenu, ordered top to bottom. Window controls may
// occupy higher layers, so only menu-item hits participate in selecting that layer.
func (h *harness) topMenuItems() []string {
	h.t.Helper()
	return topMenuItemLabels(h.driver.Snapshot().Hits)
}

func topMenuItemLabels(hits []gfx.Hit) []string {
	var top uint16
	for _, hit := range hits {
		if hit.Role == gfx.RoleMenuItem && hit.Label != "" && !hit.IsLabel {
			top = max(top, hit.Layer)
		}
	}
	var items []gfx.Hit
	for _, hit := range hits {
		if hit.Role == gfx.RoleMenuItem && hit.Label != "" && !hit.IsLabel && hit.Layer == top {
			items = append(items, hit)
		}
	}
	slices.SortStableFunc(items, func(a, b gfx.Hit) int { return cmp.Compare(a.Bounds.Y, b.Bounds.Y) })
	labels := make([]string, len(items))
	for i := range items {
		labels[i] = items[i].Label
	}
	return labels
}

// Window controls occupy a higher layer than popup menus on Linux and Windows.
// Reading menu labels must ignore those controls and still choose the deepest submenu.
func TestTopMenuItemLabelsIgnoreHigherWindowControls(t *testing.T) {
	hits := []gfx.Hit{
		{Label: "parent", Role: gfx.RoleMenuItem, Layer: 1},
		{Label: "second", Role: gfx.RoleMenuItem, Layer: 2, Bounds: gfx.Rect{Y: 40}},
		{Label: "first", Role: gfx.RoleMenuItem, Layer: 2, Bounds: gfx.Rect{Y: 20}},
		{Label: "window close", Role: gfx.RoleButton, Layer: 100},
	}
	if got, want := topMenuItemLabels(hits), []string{"first", "second"}; !slices.Equal(got, want) {
		t.Fatalf("menu labels = %q, want %q", got, want)
	}
}

func TestLogReferenceMenuMergesTheBranchAfterItIsConfirmed(t *testing.T) {
	h, p, dir := logWithTopicBranch(t)
	topic := gitRun(t, dir, "rev-parse", "topic")

	h.logRefMenu("topic")
	h.click(center(h.popupHit(h.shared("native.mergeIntoCurrentBranch"))))
	if in := p.gitHistory.integrate; !in.open || in.operation != refMerge || in.reference.ShortName != "topic" {
		t.Fatalf("the confirmation is %+v, want it open on merging topic", in)
	}
	h.click(center(h.popupHit(h.shared("native.merge"))))
	h.await("the merge", func() bool {
		return !p.gitHistory.busy && gitRun(t, dir, "rev-parse", "main") == topic
	})
}

func TestLogReferenceMenuCopiesTheBranchName(t *testing.T) {
	h, _, _ := logWithTopicBranch(t)

	h.logRefMenu("topic")
	h.click(center(h.popupHit(h.shared("git.log.copyBranchName"))))
	if got := h.driver.Clipboard(); got != "topic" {
		t.Fatalf("the clipboard holds %q, want topic", got)
	}
}

func TestLogReferenceMenuSetsAndStopsTheTrackingBranch(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	gitRun(t, dir, "remote", "add", "origin", t.TempDir())
	gitRun(t, dir, "update-ref", "refs/remotes/origin/main", "HEAD")
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)

	h.logRefMenu("main")
	h.click(center(h.popupHit(h.shared("native.trackingBranch"))))
	h.click(center(h.popupHit("origin")))
	h.click(center(h.popupHit("main")))
	h.await("the tracking branch", func() bool {
		return !h.app.branch.busy && p.log.currentReference().UpstreamShortName == "origin/main"
	})
	if got := gitRun(t, dir, "rev-parse", "--abbrev-ref", "main@{upstream}"); got != "origin/main" {
		t.Fatalf("main tracks %q, want origin/main", got)
	}

	h.logRefMenu("main")
	h.click(center(h.popupHit(h.shared("native.trackingBranch"))))
	h.click(center(h.popupHit(h.shared("native.stopTrackingBranch"))))
	h.await("no tracking branch", func() bool {
		return !h.app.branch.busy && p.log.currentReference().UpstreamShortName == ""
	})
}

// The remote branches of the tracking branch menu sit in the folders of the reference pane:
// one submenu per remote and per "/" part of a branch name, the branches named by their last part.
func TestLogReferenceTrackingMenuGroupsRemoteBranchesIntoFolders(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	for _, remote := range []string{"origin", "contributor"} {
		gitRun(t, dir, "remote", "add", remote, t.TempDir())
	}
	for _, name := range []string{"origin/main", "origin/codex/fix-one", "origin/codex/fix-two", "contributor/main"} {
		gitRun(t, dir, "update-ref", "refs/remotes/"+name, "HEAD")
	}
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)

	h.logRefMenu("main")
	h.click(center(h.popupHit(h.shared("native.trackingBranch"))))
	if got, want := h.topMenuItems(), []string{"contributor", "origin"}; !slices.Equal(got, want) {
		t.Fatalf("the tracking branch menu shows %q, want the remotes %q", got, want)
	}
	h.click(center(h.popupHit("origin")))
	if got, want := h.topMenuItems(), []string{"main", "codex"}; !slices.Equal(got, want) {
		t.Fatalf("the origin folder shows %q, want %q", got, want)
	}
	h.click(center(h.popupHit("codex")))
	if got, want := h.topMenuItems(), []string{"fix-one", "fix-two"}; !slices.Equal(got, want) {
		t.Fatalf("the codex folder shows %q, want %q", got, want)
	}
	h.click(center(h.popupHit("fix-one")))
	h.await("the tracking branch", func() bool {
		return !h.app.branch.busy && p.log.currentReference().UpstreamShortName == "origin/codex/fix-one"
	})
	if got := gitRun(t, dir, "rev-parse", "--abbrev-ref", "main@{upstream}"); got != "origin/codex/fix-one" {
		t.Fatalf("main tracks %q, want origin/codex/fix-one", got)
	}
}
