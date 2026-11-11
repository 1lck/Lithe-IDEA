package workbench

import (
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
	h.settle()
	if !v.refMenu || v.refMenuRef.ShortName != short {
		h.t.Fatalf("the reference menu is open %v on %q, want it open on %q", v.refMenu, v.refMenuRef.ShortName, short)
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
	h.click(center(h.popupHit("origin/main")))
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
