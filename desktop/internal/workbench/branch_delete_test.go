package workbench

import (
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// Deleting remote branches and several branches at once (issue #2184), through the reference pane
// of the log with real Git, real Core and a bare origin (syncFixture).

// branchDeleteFixture is syncFixture with the Git tool window open on the log.
func branchDeleteFixture(t *testing.T) (h *harness, p *project, dir, other string) {
	t.Helper()
	h, p, dir, other = syncFixture(t)
	return h, p, dir, other
}

// Local-only force deletion needs real history, but no bare remote or second clone.
func localBranchDeleteFixture(t *testing.T) (*harness, *project, string) {
	t.Helper()
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	h, p := openGitLogFixture(t, dir)
	return h, p, dir
}

// publishBranch pushes what the clone has checked out to the branch name of its origin, and fetches
// it into dir, whose log then lists origin/name.
func (h *harness) publishBranch(t *testing.T, dir, clone, name string) {
	t.Helper()
	gitRun(t, clone, "push", "origin", "HEAD:refs/heads/"+name)
	gitRun(t, dir, "fetch", "origin")
	h.app.loadLog(h.app.project)
	h.await("published remote reference", func() bool {
		_, found := h.app.project.log.findReference("refs/remotes/origin/" + name)
		return !h.app.project.log.loading && found
	})
}

// logRefRowOf is the row of the reference pane that shows the reference named short, or HEAD.
func (h *harness) logRefRowOf(short string) int {
	h.t.Helper()
	v := &h.app.logView
	i := slices.IndexFunc(v.refItems, func(r logRefRow) bool {
		return (r.kind == logRefReference || r.kind == logRefHead) && r.short == short
	})
	if i < 0 {
		h.t.Fatalf("the reference pane shows no row of %q", short)
	}
	return i
}

// clickLogRef clicks the row of the reference pane that shows short.
func (h *harness) clickLogRef(short string) {
	h.t.Helper()
	h.sendClick(center(h.topHit(h.app.logView.refs.RowID(h.logRefRowOf(short)))))
}

// clickLogRefsWith clicks the rows of the reference pane that show shorts with key held, as a person
// marks rows with Cmd, Ctrl or Shift.
func (h *harness) clickLogRefsWith(key gfx.Key, shorts ...string) {
	h.t.Helper()
	if err := h.driver.KeyDown(key, ""); err != nil {
		h.t.Fatal(err)
	}
	for _, short := range shorts {
		h.clickLogRef(short)
	}
	if err := h.driver.KeyUp(key, ""); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
}

// markLogRefs marks the rows of the reference pane that show shorts with the platform's primary
// modifier held.
func (h *harness) markLogRefs(shorts ...string) {
	h.t.Helper()
	key := gfx.KeyControlLeft
	if primaryModifier() == gfx.ModifierMeta {
		key = gfx.KeyMetaLeft
	}
	h.clickLogRefsWith(key, shorts...)
}

// markedLogNames are the short names of the branches the pane would delete together, how many
// marked rows it leaves out and whether several rows are marked.
func (h *harness) markedLogNames() (names []string, skipped int, several bool) {
	batch, skipped, several := h.app.logChosenBranches(h.app.project)
	for _, r := range batch {
		names = append(names, r.ShortName)
	}
	return names, skipped, several
}

// remoteHeads is what the origin of dir has of the branch name, empty once it is deleted there.
func remoteHeads(t *testing.T, dir, name string) string {
	t.Helper()
	return gitRun(t, dir, "ls-remote", "--heads", "origin", name)
}

// A remote branch's menu deletes it from the remote, which removes its remote-tracking branch too,
// after a confirmation that says everyone loses it.
func TestLogDeletesARemoteBranchFromItsMenu(t *testing.T) {
	h, p, dir, other := branchDeleteFixture(t)
	h.publishBranch(t, dir, other, "feature")
	if _, ok := p.log.findReference("refs/remotes/origin/feature"); !ok {
		t.Fatal("the log does not list origin/feature")
	}

	h.logRefMenu("origin/feature")
	h.sendClick(center(h.popupHit(h.app.text.Branch.Delete)))
	b := &h.app.branch
	if b.dialog != branchDialogDelete || b.target.FullName != "refs/remotes/origin/feature" || len(b.deleting) != 1 {
		t.Fatalf("dialog %v for %+v (%d branches), want the delete confirmation of origin/feature", b.dialog, b.target, len(b.deleting))
	}
	prompt := i18n.SharedFormat(h.app.language(), "desktop.branch.deleteRemotePrompt", map[string]string{"name": "origin/feature"})
	if !h.showsWrapped(prompt) {
		t.Fatalf("the dialog does not warn that the remote branch goes for everyone: %q", prompt)
	}
	h.sendClick(center(h.popupHit(h.app.text.Branch.DeleteButton)))
	h.awaitWithin(branchOperationTimeout, "the remote branch deleted", func() bool { return !b.busy && b.dialog == branchDialogNone })
	if got := remoteHeads(t, dir, "feature"); got != "" {
		t.Fatalf("remote branch still exists: %q", got)
	}
	h.awaitLogReady(h.app.project)
	if b.dialog != branchDialogNone {
		t.Fatalf("dialog %v stays open after the deletion", b.dialog)
	}
	if got := gitRun(t, dir, "branch", "-r", "--list", "origin/feature"); got != "" {
		t.Fatalf("the remote-tracking branch is still there: %q", got)
	}
	if _, ok := p.log.findReference("refs/remotes/origin/feature"); ok {
		t.Fatal("the log still lists origin/feature")
	}
	want := i18n.SharedFormat(h.app.language(), "desktop.branch.deletedRemote", map[string]string{"name": "origin/feature"})
	if got := lastNotice(h); got != want {
		t.Fatalf("notice %q, want %q", got, want)
	}
}

// Rows marked with the primary modifier or Shift are deleted together, local and remote, from the
// menu of a marked row, which offers nothing else; HEAD and the current branch are left out and
// said so.
func TestLogDeletesTheMarkedBranchesFromTheMenu(t *testing.T) {
	h, p, dir, other := branchDeleteFixture(t)
	gitRun(t, dir, "branch", "one")
	gitRun(t, dir, "branch", "two")
	h.publishBranch(t, dir, other, "feature")

	// A plain click marks nothing; a Cmd or Ctrl click marks its row and is where a Shift click
	// extends from.
	h.clickLogRef("two")
	if names, _, several := h.markedLogNames(); several || len(names) != 0 {
		t.Fatalf("a plain click marked %v", names)
	}
	h.markLogRefs("one")
	h.clickLogRefsWith(gfx.KeyShiftLeft, "two")
	h.markLogRefs("origin/feature", "main", "HEAD")
	if p.log.refSelected != "HEAD" {
		t.Fatalf("the log walks %q, want HEAD, the row clicked last", p.log.refSelected)
	}
	names, skipped, several := h.markedLogNames()
	if !several || skipped != 2 || !slices.Equal(names, []string{"one", "two", "origin/feature"}) {
		t.Fatalf("marked branches %v, %d left out, several %v; want one, two and origin/feature with HEAD and main left out", names, skipped, several)
	}
	if !h.app.logView.refNode(h.logRefRowOf("one")).Selected {
		t.Fatal("the marked row one does not show as selected")
	}

	label := i18n.SharedFormat(h.app.language(), "desktop.branch.deleteSelected", map[string]string{"count": "3"})
	point := center(h.topHit(h.app.logView.refs.RowID(h.logRefRowOf("two"))))
	if err := h.driver.ClickButton(point.X, point.Y, gfx.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if got := h.topMenuItems(); !slices.Equal(got, []string{label}) {
		t.Fatalf("the menu of a chosen row shows %q, want only %q", got, label)
	}
	h.sendClick(center(h.popupHit(label)))
	b := &h.app.branch
	if b.dialog != branchDialogDelete || len(b.deleting) != 3 || b.deleteSkipped != 2 {
		t.Fatalf("dialog %v with %d branches, %d left out; want the delete confirmation of 3 with 2 left out", b.dialog, len(b.deleting), b.deleteSkipped)
	}
	lang := h.app.language()
	for _, text := range []string{
		i18n.SharedFormat(lang, "desktop.branch.deleteManyTitle", map[string]string{"count": "3"}),
		i18n.Shared(lang, "desktop.branch.deleteManyLocal"),
		i18n.Shared(lang, "desktop.branch.deleteManyRemote"),
		i18n.SharedFormat(lang, "desktop.branch.deleteSkipped", map[string]string{"count": "2"}),
	} {
		if !h.showsWrapped(text) {
			t.Fatalf("the dialog does not show %q", text)
		}
	}
	h.sendClick(center(h.popupHit(h.app.text.Branch.DeleteButton)))
	h.awaitWithin(branchOperationTimeout, "the chosen branches deleted", func() bool { return !b.busy && b.dialog == branchDialogNone })
	h.awaitLogReady(h.app.project)
	if got := gitRun(t, dir, "branch", "--list", "one", "two"); got != "" {
		t.Fatalf("local branches left: %q", got)
	}
	if got := remoteHeads(t, dir, "feature"); got != "" {
		t.Fatalf("the remote still has feature: %q", got)
	}
	if got := gitRun(t, dir, "branch", "--list", "main"); !strings.Contains(got, "main") {
		t.Fatalf("the current branch was deleted: %q", got)
	}
	want := i18n.SharedFormat(lang, "desktop.branch.deletedMany", map[string]string{"count": "3"})
	if got := lastNotice(h); got != want {
		t.Fatalf("notice %q, want %q", got, want)
	}
	// The marks go: neither the rows left out nor a branch created again under a deleted name
	// are deleted by the next press of Delete.
	gitRun(t, dir, "branch", "one")
	h.app.loadLog(p)
	h.awaitLogReady(h.app.project)
	if refs, head := h.app.logView.markedLogRefs(p); len(refs) != 0 || head {
		t.Fatalf("after the deletion %d references are marked and HEAD %v, want none", len(refs), head)
	}
	if !h.app.logView.refNode(h.logRefRowOf("HEAD")).Selected || h.app.logView.refNode(h.logRefRowOf("one")).Selected {
		t.Fatal("after the deletion the pane does not show HEAD alone as selected")
	}
}

// The Delete button of the pane deletes the marked branches too, and every one of them is tried:
// a remote branch whose remote cannot be reached fails with Git's reason while the local branch
// marked with it is deleted.
func TestLogDeleteButtonReportsTheBranchesItCouldNotDelete(t *testing.T) {
	h, p, dir, other := branchDeleteFixture(t)
	gitRun(t, dir, "branch", "one")
	h.publishBranch(t, dir, other, "gone")
	// The origin goes away; dir keeps its remote-tracking branch. Git only warns when a reachable
	// remote lacks the branch, so an unreachable one is what makes the deletion fail.
	bare := gitRun(t, dir, "remote", "get-url", "origin")
	if err := os.Rename(bare, bare+".moved"); err != nil {
		t.Fatal(err)
	}

	h.markLogRefs("one", "origin/gone")
	h.sendNamed(h.app.text.Git.DeleteBranch)
	b := &h.app.branch
	if b.dialog != branchDialogDelete || len(b.deleting) != 2 || b.deleteSkipped != 0 {
		t.Fatalf("dialog %v with %d branches, %d left out; want the delete confirmation of one and origin/gone", b.dialog, len(b.deleting), b.deleteSkipped)
	}
	h.sendClick(center(h.popupHit(h.app.text.Branch.DeleteButton)))
	h.awaitWithin(branchOperationTimeout, "the deletion attempted", func() bool { return !b.busy && b.dialog == branchDialogDeleteResult })
	h.awaitLogReady(h.app.project)
	if got := gitRun(t, dir, "branch", "--list", "one"); got != "" {
		t.Fatalf("one is still there: %q", got)
	}
	prefix := i18n.SharedFormat(h.app.language(), "desktop.branch.deleteManyFailed", map[string]string{
		"failed": strconv.Itoa(1), "total": strconv.Itoa(2), "name": "origin/gone", "reason": ""})
	if got := lastNotice(h); !strings.HasPrefix(got, prefix) || len(got) == len(prefix) {
		t.Fatalf("notice %q, want %q followed by Git's reason", got, prefix)
	}
	if _, ok := p.log.findReference("refs/heads/one"); ok {
		t.Fatal("the log still lists one")
	}
	if !h.shows("origin/gone") || !h.shows(i18n.Shared(h.app.language(), "desktop.branch.deleteResultFailed")) {
		t.Fatal("the result does not identify the failed remote branch")
	}
}

// makeUnmergedBranch creates real unique history and returns its tip without retaining a checkout.
func makeUnmergedBranch(t *testing.T, dir, name string) string {
	t.Helper()
	gitRun(t, dir, "switch", "-c", name)
	gitRun(t, dir, "commit", "--allow-empty", "-m", "unique branch commit")
	target := gitRun(t, dir, "rev-parse", "HEAD")
	gitRun(t, dir, "switch", "main")
	return target
}

func TestLogForceDeleteRequiresSecondConfirmation(t *testing.T) {
	h, p, dir := localBranchDeleteFixture(t)
	name := "backup/before-strip-trailers"
	makeUnmergedBranch(t, dir, name)
	h.app.loadLog(p)
	h.awaitLogReady(h.app.project)
	lang := h.app.language()
	start := func() {
		h.logRefMenu(name)
		h.sendClick(center(h.popupHit(h.app.text.Branch.Delete)))
		h.sendClick(center(h.popupHit(h.app.text.Branch.DeleteButton)))
		h.awaitWithin(branchOperationTimeout, "ordinary deletion refused", func() bool { return !h.app.branch.busy })
		h.awaitLogReady(h.app.project)
		if h.app.branch.dialog != branchDialogDeleteUnmerged {
			t.Fatalf("dialog = %v, want unmerged warning", h.app.branch.dialog)
		}
		h.sendClick(center(h.popupHit(i18n.Shared(lang, "desktop.branch.reviewForceDelete"))))
		if h.app.branch.dialog != branchDialogForceDelete || h.app.branch.busy {
			t.Fatal("review did not open a separate idle confirmation")
		}
		if got := h.focusedName(); got != h.app.text.Branch.Cancel {
			t.Fatalf("initial focus = %q, want Cancel", got)
		}
		if !h.showsWrapped(i18n.Shared(lang, "desktop.branch.forceDeletePrompt")) {
			t.Fatal("confirmation omits the unmerged-commit warning")
		}
		if got := gitRun(t, dir, "branch", "--list", name); got == "" {
			t.Fatal("branch was deleted before the second confirmation")
		}
	}
	start()
	// The new modal starts on Cancel. Enter must never approve destructive force deletion.
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	h.awaitLogReady(h.app.project)
	if h.app.branch.dialog != branchDialogNone || gitRun(t, dir, "branch", "--list", name) == "" {
		t.Fatal("Enter did not cancel safely")
	}
	start()
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.awaitLogReady(h.app.project)
	if h.app.branch.dialog != branchDialogNone || gitRun(t, dir, "branch", "--list", name) == "" {
		t.Fatal("Escape did not cancel safely")
	}
	start()
	h.sendClick(center(h.popupHit(i18n.Shared(lang, "desktop.branch.forceDelete"))))
	h.awaitWithin(branchOperationTimeout, "forced deletion completed", func() bool { return !h.app.branch.busy })
	h.awaitLogReady(h.app.project)
	if h.app.branch.dialog != branchDialogNone || gitRun(t, dir, "branch", "--list", name) != "" {
		t.Fatal("confirmed force deletion did not remove the branch")
	}
}

func TestLogForceDeleteBatchOnlyRetriesUnmergedAndRejectsChangedTip(t *testing.T) {
	h, p, dir := localBranchDeleteFixture(t)
	name := "backup/unmerged"
	old := makeUnmergedBranch(t, dir, name)
	gitRun(t, dir, "branch", "merged")
	h.app.loadLog(p)
	h.awaitLogReady(h.app.project)
	h.markLogRefs("merged", name)
	h.sendNamed(h.app.text.Git.DeleteBranch)
	h.sendClick(center(h.popupHit(h.app.text.Branch.DeleteButton)))
	h.awaitWithin(branchOperationTimeout, "batch deletion completed", func() bool { return !h.app.branch.busy })
	h.awaitLogReady(h.app.project)
	b := &h.app.branch
	if b.dialog != branchDialogDeleteUnmerged || len(b.deleting) != 1 || b.deleting[0].ShortName != name {
		t.Fatalf("force retry selection = %+v, dialog = %v", b.deleting, b.dialog)
	}
	if gitRun(t, dir, "branch", "--list", "merged") != "" {
		t.Fatal("ordinary deletion left the merged branch")
	}
	h.sendClick(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.branch.reviewForceDelete"))))
	// An external writer moves the target after review, with no timing-based synchronization.
	current := gitRun(t, dir, "rev-parse", "main")
	gitRun(t, dir, "update-ref", "refs/heads/"+name, current, old)
	h.sendClick(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.branch.forceDelete"))))
	h.awaitWithin(branchOperationTimeout, "stale confirmation refused", func() bool { return !b.busy })
	h.awaitLogReady(h.app.project)
	if got := gitRun(t, dir, "rev-parse", "refs/heads/"+name); got != current {
		t.Fatalf("changed branch was deleted or moved: %s", got)
	}
	if b.dialog != branchDialogDeleteResult || len(b.deleteReport.unmerged) != 0 || !strings.Contains(lastNotice(h), i18n.Shared(h.app.language(), "desktop.branch.deleteChanged")) {
		t.Fatal("stale force confirmation was retained or change was not explained")
	}
}

func TestLogForceDeleteMixedBatchRetainsEveryOutcome(t *testing.T) {
	h, _, dir, other := branchDeleteFixture(t)
	name := "backup/unmerged"
	makeUnmergedBranch(t, dir, name)
	makeUnmergedBranch(t, dir, "backup/busy")
	gitRun(t, dir, "branch", "merged")
	h.publishBranch(t, dir, other, "gone")
	bare := gitRun(t, dir, "remote", "get-url", "origin")
	if err := os.Rename(bare, bare+".moved"); err != nil {
		t.Fatal(err)
	}
	h.clickLogRef("merged")
	h.markLogRefs(name, "backup/busy", "origin/gone")
	if names, _, several := h.markedLogNames(); !several || len(names) != 4 {
		t.Fatalf("plain click followed by primary clicks selected %v", names)
	}
	h.sendNamed(h.app.text.Git.DeleteBranch)
	h.sendClick(center(h.popupHit(h.app.text.Branch.DeleteButton)))
	b := &h.app.branch
	h.awaitWithin(branchOperationTimeout, "mixed batch attempted", func() bool { return !b.busy })
	h.awaitLogReady(h.app.project)
	if b.dialog != branchDialogDeleteUnmerged || len(b.deleting) != 2 || len(b.deleteReport.results) != 4 {
		t.Fatalf("mixed result lost a branch or included a non-unmerged force target: %+v", b)
	}
	if b.deleteReport.results[slices.IndexFunc(b.deleteReport.results, func(d branchDeletion) bool { return d.branch.ShortName == "merged" })].err != nil {
		t.Fatal("merged branch did not succeed")
	}
	for _, key := range []string{"deleteResultDeleted", "deleteResultFailed", "deleteResultUnmerged"} {
		if !h.shows(i18n.Shared(h.app.language(), "desktop.branch."+key)) {
			t.Fatalf("mixed result does not show %s", key)
		}
	}
	// A branch created again under a successful name must not be retried by force.
	gitRun(t, dir, "branch", "merged")
	h.sendClick(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.branch.reviewForceDelete"))))
	// Another worktree checks out a reviewed branch before force executes. Only that branch
	// fails; the remaining unmerged branch still deletes and earlier remote failure stays visible.
	gitRun(t, dir, "worktree", "add", t.TempDir(), "backup/busy")
	h.sendClick(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.branch.forceDelete"))))
	h.awaitWithin(branchOperationTimeout, "only unmerged branch force deleted", func() bool { return !b.busy })
	h.awaitLogReady(h.app.project)
	if b.dialog != branchDialogDeleteResult || gitRun(t, dir, "branch", "--list", name) != "" || gitRun(t, dir, "branch", "--list", "merged") == "" {
		t.Fatal("force retry removed a successful branch again or kept the confirmed branch")
	}
	if gitRun(t, dir, "show-ref", "--verify", "refs/remotes/origin/gone") == "" {
		t.Fatal("unreachable remote branch was removed locally")
	}
	if gitRun(t, dir, "branch", "--list", "backup/busy") == "" {
		t.Fatal("force deleted a branch checked out in another worktree")
	}
	if len(b.deleteReport.unmerged) != 0 || len(b.deleteReport.results) != 4 {
		t.Fatal("force completion lost original outcomes or retained stale reviews")
	}
}
