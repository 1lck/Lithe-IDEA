package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// refusingKernel is Core's client that refuses every checkout and every new branch in the
// repository whose folder is named refused, as a repository Git cannot switch does.
type refusingKernel struct {
	*gitKernel
	refused string
}

// errRefusedByTest is what refusingKernel answers for the refused repository.
var errRefusedByTest = errors.New("refused by the test")

func (k *refusingKernel) GitCheckout(ctx context.Context, root string, reference core.GitReference, mode core.CheckoutMode) error {
	if filepath.Base(root) == k.refused {
		return errRefusedByTest
	}
	return k.gitKernel.GitCheckout(ctx, root, reference, mode)
}

func (k *refusingKernel) GitCreateBranch(ctx context.Context, root, name string, from core.GitReference, checkout bool) error {
	if filepath.Base(root) == k.refused {
		return errRefusedByTest
	}
	return k.gitKernel.GitCreateBranch(ctx, root, name, from, checkout)
}

// openCommonBranches opens the branch popup of the open folder and waits until Core listed the
// branches every repository has.
func (h *harness) openCommonBranches() *branchState {
	h.t.Helper()
	h.branchClick(center(h.hitLabeled(h.app.text.Title.BranchMenu)))
	b := &h.app.branch
	h.settleUntil("the common branches", func() bool { return b.common.loaded })
	if b.common.err != nil {
		h.t.Fatalf("reading the common branches: %v", b.common.err)
	}
	return b
}

func (h *harness) branchClick(point gfx.Point) {
	h.t.Helper()
	h.sendClick(point)
	h.awaitWithin(branchOperationTimeout, "branch operation", func() bool {
		b := &h.app.branch
		return !b.busy && !b.loading && !b.common.loading
	})
}

func (h *harness) branchNamed(name string) {
	h.t.Helper()
	h.branchClick(center(h.pageHit(name).Bounds))
}

func (h *harness) typeCommonBranchName(name string, clear func(), value string) {
	h.t.Helper()
	clear()
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
	h.sendNamed(name)
	if err := h.driver.Type(value); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
}

// shortNames are the short names of refs.
func shortNames(refs []core.GitReference) []string {
	out := make([]string, len(refs))
	for i, r := range refs {
		out[i] = r.ShortName
	}
	return out
}

// branchesOf are the local branches of the repository in dir, sorted.
func branchesOf(t *testing.T, dir string) []string {
	t.Helper()
	return slices.Sorted(slices.Values(strings.Fields(gitRun(t, dir, "branch", "--format=%(refname:short)"))))
}

// The popup of a folder holding repositories lists, under the repositories, the branches every one
// of them has, as IDEA's Common Local Branches; a checkout there switches every repository.
func TestWorkspaceBranchPopupChecksOutACommonBranchInEveryRepository(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	alpha, beta := filepath.Join(parent, "alpha"), filepath.Join(parent, "beta")
	gitRun(t, alpha, "branch", "feature")
	gitRun(t, beta, "branch", "feature")
	gitRun(t, alpha, "branch", "only-alpha")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	b := h.openCommonBranches()

	common := shortNames(b.common.sections[0].refs)
	if !slices.Contains(common, "feature") || !slices.Contains(common, "main") || slices.Contains(common, "only-alpha") {
		t.Fatalf("common local branches = %v, want feature and main without only-alpha", common)
	}
	if current := b.common.current(); current.ShortName != "main" {
		t.Fatalf("common current branch = %q, want main, which both repositories are on", current.ShortName)
	}
	lang := h.app.language()
	if want := i18n.Shared(lang, "desktop.branch.commonLocal"); !h.shows(want) {
		t.Fatalf("the popup does not show %q", want)
	}
	if h.shows("only-alpha") {
		t.Fatal("the popup lists only-alpha, which beta does not have, among the common branches")
	}

	h.branchClick(center(h.branchRow("feature")))
	if b.menu != branchRowKey(commonSectionKeys[0], b.common.sections[0].refs[slices.Index(common, "feature")]) {
		t.Fatalf("menu %q is open, want the common feature row's", b.menu)
	}
	h.branchNamed(h.app.text.Branch.Checkout)
	for _, dir := range []string{alpha, beta} {
		if got := currentBranch(t, dir); got != "feature" {
			t.Fatalf("%s is on %q, want feature", filepath.Base(dir), got)
		}
	}
	if want := i18n.SharedFormat(lang, "desktop.branch.commonCheckedOut", map[string]string{"name": "feature"}); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
	alphaID, betaID := repositoryID(t, p, "alpha"), repositoryID(t, p, "beta")
	h.settleUntil("both repositories' new branch", func() bool {
		return p.branchOf(alphaID) == "feature" && p.branchOf(betaID) == "feature"
	})
}

// A checkout of a common branch that fails in a repository after it switched another offers IDEA's
// Rollback, which returns the switched one to the branch it was on.
func TestWorkspaceCommonCheckoutRollsBackAfterAPartialFailure(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	alpha, beta := filepath.Join(parent, "alpha"), filepath.Join(parent, "beta")
	gitRun(t, alpha, "branch", "feature")
	gitRun(t, beta, "branch", "feature")
	h := newHarness(t, &refusingKernel{gitKernel: &gitKernel{Client: core.NewClient()}, refused: "beta"})
	h.openWorkspaceFolder(parent)
	b := h.openCommonBranches()

	h.branchClick(center(h.branchRow("feature")))
	h.branchNamed(h.app.text.Branch.Checkout)
	if b.dialog != branchDialogRollback || !b.across {
		t.Fatalf("after beta refused: dialog %v across %v, want the rollback dialog", b.dialog, b.across)
	}
	if got := currentBranch(t, alpha); got != "feature" {
		t.Fatalf("alpha is on %q, want feature before the rollback", got)
	}
	if got := currentBranch(t, beta); got != "main" {
		t.Fatalf("beta is on %q, want main, where its refused checkout left it", got)
	}
	lang := h.app.language()
	failed := i18n.SharedFormat(lang, "desktop.branch.checkoutFailedIn", map[string]string{
		"name": "feature", "repository": "beta", "reason": errRefusedByTest.Error()})
	if !h.showsWrapped(failed) {
		t.Fatalf("the rollback dialog does not say %q", failed)
	}

	h.branchNamed(i18n.Shared(lang, "desktop.branch.rollbackButton"))
	if got := currentBranch(t, alpha); got != "main" {
		t.Fatalf("alpha is on %q after the rollback, want main", got)
	}
	if b.dialog != branchDialogNone || b.across {
		t.Fatalf("after the rollback: dialog %v across %v", b.dialog, b.across)
	}
	if want := i18n.SharedFormat(lang, "desktop.branch.rolledBack", map[string]string{"repositories": "alpha"}); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
}

// A new branch from a common branch is checked against the branches of every repository and created
// in all of them; when one refuses it, the rollback switches the others back and deletes it there.
func TestWorkspaceCommonNewBranchIsCreatedInEveryRepository(t *testing.T) {
	for _, refused := range []string{"", "beta"} {
		t.Run("refused="+refused, func(t *testing.T) {
			parent := newWorkspaceFolder(t, "alpha", "beta")
			alpha, beta := filepath.Join(parent, "alpha"), filepath.Join(parent, "beta")
			gitRun(t, alpha, "branch", "only-alpha")
			h := newHarness(t, &refusingKernel{gitKernel: &gitKernel{Client: core.NewClient()}, refused: refused})
			h.openWorkspaceFolder(parent)
			b := h.openCommonBranches()
			text, lang := h.app.text.Branch, h.app.language()

			h.branchClick(center(h.branchRow("main")))
			if _, ok := h.findPageHit(text.Checkout); ok {
				t.Fatal("the menu of main, which every repository is on, offers a checkout")
			}
			h.branchNamed(text.NewBranchFrom("main"))
			if b.dialog != branchDialogCreate || !b.across {
				t.Fatalf("after New Branch from main: dialog %v across %v", b.dialog, b.across)
			}
			if want := i18n.SharedFormat(lang, "desktop.branch.createFromInAll", map[string]string{"name": "main"}); !h.showsWrapped(want) {
				t.Fatalf("the dialog does not say %q", want)
			}
			clear := func() { b.name.SetText("") }
			h.typeCommonBranchName(text.BranchName, clear, "only-alpha")
			if want := text.NameExists("only-alpha"); !h.shows(want) {
				t.Fatalf("the dialog does not say %q for a branch alpha has", want)
			}
			h.typeCommonBranchName(text.BranchName, clear, "topic")
			h.branchNamed(text.Create)

			if refused == "" {
				for _, dir := range []string{alpha, beta} {
					if got := currentBranch(t, dir); got != "topic" {
						t.Fatalf("%s is on %q, want the new topic", filepath.Base(dir), got)
					}
				}
				if want := i18n.SharedFormat(lang, "desktop.branch.commonCreated", map[string]string{"name": "topic"}); h.app.notice != want {
					t.Fatalf("notice = %q, want %q", h.app.notice, want)
				}
				return
			}
			if b.dialog != branchDialogRollback {
				t.Fatalf("after beta refused: dialog %v, want the rollback dialog", b.dialog)
			}
			h.branchNamed(i18n.Shared(lang, "desktop.branch.rollbackButton"))
			if got := currentBranch(t, alpha); got != "main" {
				t.Fatalf("alpha is on %q after the rollback, want main", got)
			}
			if got := branchesOf(t, alpha); !slices.Equal(got, []string{"main", "only-alpha"}) {
				t.Fatalf("alpha has %v after the rollback, want topic deleted", got)
			}
		})
	}
}

// A checkout of a common branch that would overwrite local changes in a repository lists them under
// that repository's ID, and the choice of the conflict dialog applies to every repository.
func TestWorkspaceCommonCheckoutListsTheBlockingChangesOfEveryRepository(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	alpha, beta := filepath.Join(parent, "alpha"), filepath.Join(parent, "beta")
	gitRun(t, alpha, "branch", "feature")
	// beta's feature changes beta.txt, which beta has modified.
	gitRun(t, beta, "stash", "push", "-m", "keep")
	gitRun(t, beta, "checkout", "-b", "feature")
	if err := os.WriteFile(filepath.Join(beta, "beta.txt"), []byte("feature\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, beta, "commit", "-am", "feature beta")
	gitRun(t, beta, "checkout", "main")
	gitRun(t, beta, "stash", "pop")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	b := h.openCommonBranches()

	h.branchClick(center(h.branchRow("feature")))
	h.branchNamed(h.app.text.Branch.Checkout)
	betaID := repositoryID(t, p, "beta")
	if b.dialog != branchDialogConflict || !b.across {
		t.Fatalf("dialog %v across %v, want the conflict dialog of the common checkout", b.dialog, b.across)
	}
	if want := []string{betaID + "/beta.txt"}; !slices.Equal(b.blocking, want) {
		t.Fatalf("blocking paths = %v, want %v", b.blocking, want)
	}
	if got := currentBranch(t, alpha); got != "main" {
		t.Fatalf("alpha is on %q, want main while the dialog asks", got)
	}

	h.branchNamed(h.app.text.Branch.ForceCheckout)
	for _, dir := range []string{alpha, beta} {
		if got := currentBranch(t, dir); got != "feature" {
			t.Fatalf("%s is on %q, want feature", filepath.Base(dir), got)
		}
	}
	if b.dialog != branchDialogNone || b.across {
		t.Fatalf("after the forced checkout: dialog %v across %v", b.dialog, b.across)
	}
}
