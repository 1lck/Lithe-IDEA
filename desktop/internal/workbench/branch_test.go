package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// openBranches opens dir and the branch popup, and waits for the references.
func (h *harness) openBranches(dir string) *project {
	h.t.Helper()
	h.open(dir)
	h.settle()
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		h.t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	h.click(center(h.hitLabeled(h.app.text.Title.BranchMenu)))
	if !h.app.branch.open || !h.app.branch.loaded {
		h.t.Fatalf("branch popup open %v, loaded %v", h.app.branch.open, h.app.branch.loaded)
	}
	if err := h.app.branch.err; err != nil {
		h.t.Fatalf("reading the references: %v", err)
	}
	return p
}

// branchRow is where the row of the reference named name was laid out in the last frame:
// the first one, as the recent branches are listed again under Local.
func (h *harness) branchRow(name string) gfx.Rect {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleMenuItem && hit.Label == name {
			return hit.Bounds
		}
	}
	h.t.Fatalf("no row for %q in the branch popup", name)
	return gfx.Rect{}
}

// popupHit is the control named label on the topmost layer, the open popup, so a control of
// the same name in the window behind it does not match.
func (h *harness) popupHit(label string) gfx.Rect {
	h.t.Helper()
	var found *gfx.Hit
	hits := h.driver.Snapshot().Hits
	for i := range hits {
		if hits[i].Label == label && !hits[i].IsLabel && (found == nil || hits[i].Layer > found.Layer) {
			found = &hits[i]
		}
	}
	if found == nil {
		h.t.Fatalf("no control named %q is shown", label)
		return gfx.Rect{}
	}
	return found.Bounds
}

// typeInto empties field, clicks the control named name and types value into it.
func (h *harness) typeInto(name string, clear func(), value string) {
	h.t.Helper()
	clear()
	h.settle()
	h.clickNamed(name)
	if err := h.driver.Type(value); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
}

func currentBranch(t *testing.T, dir string) string {
	t.Helper()
	return gitRun(t, dir, "branch", "--show-current")
}

func TestBranchPopupCreatesABranchWithACleanedName(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.openBranches(dir)
	if !h.shows("main") {
		t.Fatal("the popup does not list main")
	}

	h.clickNamed(h.app.text.Branch.NewBranch)
	b := &h.app.branch
	if b.open || b.dialog != branchDialogCreate {
		t.Fatalf("after New Branch: popup open %v, dialog %v", b.open, b.dialog)
	}
	clear := func() { b.name.SetText("") }
	h.typeInto(h.app.text.Branch.BranchName, clear, "main")
	if want := h.app.text.Branch.NameExists("main"); !h.shows(want) {
		t.Fatalf("the dialog does not say %q", want)
	}

	h.typeInto(h.app.text.Branch.BranchName, clear, "my branch")
	if got := b.name.Text(); got != "my-branch" {
		t.Fatalf("name field = %q, want the kernel's cleaned my-branch", got)
	}
	h.clickNamed(h.app.text.Branch.Create)
	if got := currentBranch(t, dir); got != "my-branch" {
		t.Fatalf("current branch = %q, want my-branch", got)
	}
	if b.dialog != branchDialogNone || h.app.project.git.branch() != "my-branch" {
		t.Fatalf("after creating: dialog %v, title bar branch %q", b.dialog, h.app.project.git.branch())
	}
	if want := h.app.text.Branch.Created("my-branch"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
}

// A checkout from the title bar's branch popup shows the Console tab of the Git tool window,
// where the commands it ran are.
func TestBranchRowMenuChecksOutABranch(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "branch", "other")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.openBranches(dir)
	h.app.layout.gitTab = gitTabLog

	h.click(center(h.branchRow("other")))
	if h.app.branch.menu == "" {
		t.Fatal("clicking the row did not open its menu")
	}
	h.clickNamed(h.app.text.Branch.Checkout)
	if got := currentBranch(t, dir); got != "other" {
		t.Fatalf("current branch = %q, want other", got)
	}
	if want := h.app.text.Branch.CheckedOut("other"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
	if h.app.branch.open {
		t.Fatal("the popup stayed open after the checkout")
	}
	if h.app.layout.gitTab != gitTabConsole || !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		t.Fatalf("after the checkout: Git tab %d, Git open %v; want the Console", h.app.layout.gitTab, h.app.chrome.isOpen(catalogIndex[itemGit]))
	}
}

func TestBranchCheckoutAsksAboutChangesItWouldOverwrite(t *testing.T) {
	dir := newTestRepository(t)
	// other changes changed.txt, which is also modified in the working tree.
	gitRun(t, dir, "stash")
	gitRun(t, dir, "checkout", "-b", "other")
	if err := os.WriteFile(filepath.Join(dir, "changed.txt"), []byte("third\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "commit", "-am", "third")
	gitRun(t, dir, "checkout", "main")
	gitRun(t, dir, "stash", "pop")

	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.openBranches(dir)
	h.click(center(h.branchRow("other")))
	h.clickNamed(h.app.text.Branch.Checkout)
	b := &h.app.branch
	if b.dialog != branchDialogConflict || len(b.blocking) != 1 || b.blocking[0] != "changed.txt" {
		t.Fatalf("dialog %v, blocking %v; want the conflict dialog for changed.txt", b.dialog, b.blocking)
	}
	if got := currentBranch(t, dir); got != "main" {
		t.Fatalf("the branch changed to %q before the user chose", got)
	}

	h.clickNamed(h.app.text.Branch.ForceCheckout)
	if got := currentBranch(t, dir); got != "other" {
		t.Fatalf("current branch after the forced checkout = %q, want other", got)
	}
	content, err := os.ReadFile(filepath.Join(dir, "changed.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "third\n" {
		t.Fatalf("changed.txt = %q, want other's third", content)
	}
}

func TestBranchDeleteAsksFirst(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "branch", "stale")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.openBranches(dir)

	h.click(center(h.branchRow("stale")))
	h.clickNamed(h.app.text.Branch.Delete)
	if h.app.branch.dialog != branchDialogDelete {
		t.Fatalf("dialog = %v, want the delete confirmation", h.app.branch.dialog)
	}
	if got := gitRun(t, dir, "branch", "--list", "stale"); got == "" {
		t.Fatal("the branch was deleted before the user confirmed")
	}
	h.clickNamed(h.app.text.Branch.DeleteButton)
	if got := gitRun(t, dir, "branch", "--list", "stale"); got != "" {
		t.Fatalf("branch list after deleting = %q, want none", got)
	}
}

func TestBranchPopupClosesOnEscape(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "branch", "other")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.openBranches(dir)
	h.click(center(h.branchRow("other")))

	escape := func() {
		if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
	escape()
	if !h.app.branch.open || h.app.branch.menu != "" {
		t.Fatalf("first Escape: popup open %v, menu %q; want only the row menu closed", h.app.branch.open, h.app.branch.menu)
	}
	escape()
	if h.app.branch.open {
		t.Fatal("second Escape left the popup open")
	}
}

// The popup lists a namespaced branch in a closed folder of Core's reference tree, and the
// menu of its row opens beside the row, with IDEA's comparisons, update and push. Push opens
// the Push dialog on that branch rather than the checked-out one.
func TestBranchPopupFoldsNamespacesAndOpensTheRowMenuBeside(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "branch", "feature/one")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openBranches(dir)

	hasRow := func(name string) bool {
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.Role == gfx.RoleMenuItem && hit.Label == name {
				return true
			}
		}
		return false
	}
	// Recent lists feature/one flat, since Core counts a new branch as recent; fold it so only
	// the Local tree can show the row.
	h.click(center(h.popupHit(h.app.text.Branch.Recent)))
	if hasRow("feature/one") {
		t.Fatal("feature/one is listed before its folder was opened")
	}
	h.click(center(h.popupHit("feature")))
	if !hasRow("feature/one") {
		t.Fatal("opening the feature folder did not list feature/one")
	}

	row := h.branchRow("feature/one")
	h.click(center(row))
	if h.app.branch.menu == "" {
		t.Fatal("clicking the row did not open its menu")
	}
	git := h.app.text.Git
	for _, item := range []string{git.CompareWorkingTree, git.CompareWithCurrent, h.app.text.Branch.Checkout} {
		if !h.shows(item) {
			t.Fatalf("the row menu does not offer %q", item)
		}
	}
	compare := h.popupHit(git.CompareWorkingTree)
	if compare.X < row.X+row.Width {
		t.Fatalf("menu item at x %v, row ends at %v; want the menu beside the row", compare.X, row.X+row.Width)
	}

	h.clickNamed(i18n.Shared(h.app.language(), "git.contextMenu.push"))
	s := &p.review.push
	if h.app.branch.open || !s.open || s.branch.ShortName != "feature/one" {
		t.Fatalf("after Push: popup open %v, Push dialog open %v on %q; want the dialog on feature/one",
			h.app.branch.open, s.open, s.branch.ShortName)
	}
}
