package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// newWorkspaceFolder is a folder that is no repository itself holding one repository per name,
// each on main with the commit "initial <name>" and the modified file <name>.txt, not staged.
func newWorkspaceFolder(t *testing.T, names ...string) string {
	t.Helper()
	requireTestGit(t)
	parent := t.TempDir()
	for _, name := range names {
		dir := filepath.Join(parent, name)
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		gitRun(t, dir, "init")
		gitRun(t, dir, "symbolic-ref", "HEAD", "refs/heads/main")
		file := filepath.Join(dir, name+".txt")
		if err := os.WriteFile(file, []byte("first\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		gitRun(t, dir, "add", name+".txt")
		gitRun(t, dir, "commit", "-m", "initial "+name)
		if err := os.WriteFile(file, []byte("second\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return parent
}

// openWorkspaceFolder opens dir, a folder holding repositories, and waits until its repositories
// and their changes were read.
func (h *harness) openWorkspaceFolder(dir string) *project {
	h.t.Helper()
	h.app.delays = logDelays{}
	h.app.openProject(dir)
	h.settleUntil("reading the nested repositories", func() bool {
		p := h.app.project
		return p != nil && p.workspaceMode() && p.nested.grouped
	})
	p := h.app.project
	if p.git.isRepository() {
		h.t.Fatalf("the project folder is a repository itself: %+v", p.git.status)
	}
	return p
}

// repositoryID is Core's ID of the nested repository named name.
func repositoryID(t *testing.T, p *project, name string) string {
	t.Helper()
	for _, repo := range p.nested.repos {
		if repo.name == name {
			return repo.id
		}
	}
	t.Fatalf("no nested repository named %q in %+v", name, p.nested.repos)
	return ""
}

// The branch popup of a folder holding repositories lists them as IDEA does, each with its branch;
// the panel a row opens beside it lists that repository's branches, and a checkout there switches
// that repository alone.
func TestWorkspaceBranchPopupChecksOutInTheRepositoryOfItsPanel(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	alpha, beta := filepath.Join(parent, "alpha"), filepath.Join(parent, "beta")
	gitRun(t, beta, "branch", "other")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	if got := p.titleBranch(); got != "main" {
		t.Fatalf("title bar branch = %q, want the first repository's main", got)
	}

	h.click(center(h.hitLabeled(h.app.text.Title.BranchMenu)))
	b := &h.app.branch
	if !b.open {
		t.Fatal("the branch popup did not open for a folder holding repositories")
	}
	lang := h.app.language()
	repoRow := func(name, branch string) string {
		return i18n.SharedFormat(lang, "desktop.branch.repositoryPanel", map[string]string{"repository": name, "branch": branch})
	}
	for _, name := range []string{"alpha", "beta"} {
		if _, ok := h.findPageHit(repoRow(name, "main")); !ok {
			t.Fatalf("the popup has no row %q", repoRow(name, "main"))
		}
	}
	if b.repoOpen {
		t.Fatal("a repository panel is open before a row was clicked")
	}

	row := h.popupHit(repoRow("beta", "main"))
	h.click(center(row))
	if !b.repoOpen || filepath.Base(b.repo) != "beta" || !b.loaded || b.err != nil {
		t.Fatalf("after clicking beta: panel open %v on %q, loaded %v, err %v", b.repoOpen, b.repo, b.loaded, b.err)
	}
	if want := i18n.SharedFormat(lang, "desktop.branch.localIn", map[string]string{"repository": "beta"}); !h.shows(want) {
		t.Fatalf("the panel does not show %q", want)
	}
	other := h.branchRow("other")
	if other.X < row.X+row.Width {
		t.Fatalf("branch row at x %v, repository row ends at %v; want the panel beside the row", other.X, row.X+row.Width)
	}

	h.click(center(other))
	if b.menu == "" {
		t.Fatal("clicking the branch row did not open its menu")
	}
	h.clickNamed(h.app.text.Branch.Checkout)
	if got := currentBranch(t, beta); got != "other" {
		t.Fatalf("beta is on %q, want other", got)
	}
	if got := currentBranch(t, alpha); got != "main" {
		t.Fatalf("alpha is on %q, want it left on main", got)
	}
	betaID := repositoryID(t, p, "beta")
	h.settleUntil("reading beta's new branch", func() bool { return p.branchOf(betaID) == "other" })
}

// The Paths filter of a folder holding repositories lists them under Roots; a click walks that
// repository's history, and the writes of the log act on it.
func TestWorkspaceLogRootsWalkTheChosenRepository(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	alphaID, betaID := repositoryID(t, p, "alpha"), repositoryID(t, p, "beta")
	h.app.layout.gitTab = gitTabLog
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.click(center(h.button(itemGit)))
	}
	h.settleUntil("alpha's history", func() bool { return p.logRepoID() == alphaID && !p.log.loading && len(p.log.graph.Rows) == 1 })
	if !h.shows("initial alpha") {
		t.Fatal("the log does not show alpha's commit")
	}
	for _, id := range []string{alphaID, betaID} {
		if _, ok := p.repositorySlot(id); !ok {
			t.Fatalf("repository %q has no color slot for the log's strip", id)
		}
	}

	g := h.app.text.Git
	// The chip is the first control of that name; the window's path bar below shares it.
	h.click(center(h.hitLabeled(g.FilterPaths)))
	if p.log.popover != logPopoverPath {
		t.Fatalf("popover %v after clicking the Paths chip, want the Paths filter", p.log.popover)
	}
	if roots := i18n.Shared(h.app.language(), "desktop.nested.roots"); !h.shows(roots) {
		t.Fatalf("the Paths filter has no %q section", roots)
	}
	h.clickNamed("beta")
	h.settleUntil("beta's history", func() bool { return p.logRepoID() == betaID && !p.log.loading && len(p.log.graph.Rows) == 1 })
	if p.log.popover != logPopoverNone {
		t.Fatalf("popover %v after choosing a root, want it closed", p.log.popover)
	}
	if !h.shows("initial beta") {
		t.Fatal("the log does not show beta's commit")
	}
	if got := filepath.Base(p.logRepositoryRoot()); got != "beta" {
		t.Fatalf("the log's writes act on %q, want beta", got)
	}
	if got := p.titleBranch(); got != "main" {
		t.Fatalf("title bar branch = %q, want beta's main", got)
	}
}

// Opening a folder that is not a repository itself—whether it holds nested repositories or is
// empty—must never query Git references at the non-repository folder root or leave failed commands
// in the Git console.
func TestNonRepositoryFolderDoesNotQueryRootReferencesInGitConsole(t *testing.T) {
	assertNoFailedConsoleRecords := func(t *testing.T, h *harness) {
		t.Helper()
		for _, r := range h.app.gitConsole.Snapshot().Records {
			if r.Error != "" || (r.Exited && r.ExitCode != 0 && !r.ExpectedExit) {
				t.Fatalf("unexpected failed Git console record: root=%q args=%v exit=%d err=%q", r.Root, r.Arguments, r.ExitCode, r.Error)
			}
		}
	}

	t.Run("nested repositories", func(t *testing.T) {
		parent := newWorkspaceFolder(t, "alpha", "beta")
		h := newHarness(t, &gitKernel{Client: core.NewClient()})
		p := h.openWorkspaceFolder(parent)
		alphaID := repositoryID(t, p, "alpha")
		h.app.layout.gitTab = gitTabLog
		if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
			h.click(center(h.button(itemGit)))
		}
		h.settleUntil("alpha's history", func() bool {
			return p.logRepoID() == alphaID && !p.log.loading && len(p.log.graph.Rows) == 1
		})
		assertNoFailedConsoleRecords(t, h)
	})

	t.Run("empty folder", func(t *testing.T) {
		requireTestGit(t)
		empty := t.TempDir()
		h := newHarness(t, &gitKernel{Client: core.NewClient()})
		h.app.delays = logDelays{}
		h.open(empty)
		h.app.layout.gitTab = gitTabLog
		if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
			h.click(center(h.button(itemGit)))
		}
		h.settle()
		p := h.app.project
		if !h.shows(h.app.text.Git.NotRepository) {
			t.Fatalf("expected %q on empty folder log tab", h.app.text.Git.NotRepository)
		}
		// Refreshing the log on a non-repository folder must also stay silent.
		h.app.loadLog(p)
		h.settle()
		assertNoFailedConsoleRecords(t, h)
	})

	t.Run("initialized later", func(t *testing.T) {
		requireTestGit(t)
		dir := t.TempDir()
		h := newHarness(t, &gitKernel{Client: core.NewClient()})
		h.app.delays = logDelays{}
		h.open(dir)
		h.app.layout.gitTab = gitTabLog
		if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
			h.click(center(h.button(itemGit)))
		}
		h.settle()
		assertNoFailedConsoleRecords(t, h)

		gitRun(t, dir, "init")
		gitRun(t, dir, "symbolic-ref", "HEAD", "refs/heads/main")
		if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("hello\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		gitRun(t, dir, "add", "readme.txt")
		gitRun(t, dir, "commit", "-m", "late init")

		p := h.app.project
		h.app.loadGit(p)
		h.settleUntil("late repository history", func() bool {
			return p.git.isRepository() && !p.log.loading && len(p.log.graph.Rows) == 1
		})
		if !h.shows("late init") {
			t.Fatal("the log did not load after the folder became a Git repository")
		}
		assertNoFailedConsoleRecords(t, h)
	})
}

// The Commit tool window of a folder holding repositories groups the changes by repository, and
// its Commit button commits the staged changes of each.
func TestWorkspaceCommitCommitsEveryNestedRepository(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	h.click(center(h.button(itemCommit)))
	for _, name := range []string{"alpha", "beta", "alpha.txt", "beta.txt"} {
		if !h.shows(name) {
			t.Fatalf("the Commit window does not show %q", name)
		}
	}
	if want := h.app.text.Status.Changes(2); !h.shows(want) {
		t.Fatalf("the status bar does not count the nested repositories' changes as %q", want)
	}

	h.clickNamed(h.app.text.Commit.ChangeList)
	h.settleUntil("staging both repositories", func() bool { return p.nestedStagedCount() == 2 })
	h.clickNamed(h.app.text.Commit.MessageLabel)
	if err := h.driver.Type("Change both"); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !p.canCommit() {
		t.Fatalf("the commit button is disabled with %d staged changes and message %q", p.nestedStagedCount(), p.commit.message())
	}
	h.clickNamed(h.app.text.Commit.Commit)
	h.settle()
	for _, name := range []string{"alpha", "beta"} {
		if got := gitRun(t, filepath.Join(parent, name), "log", "-1", "--format=%s"); got != "Change both" {
			t.Fatalf("last commit of %s = %q, want the typed message", name, got)
		}
	}
	h.settleUntil("reading the committed repositories", func() bool { return p.nestedStagedCount() == 0 })
}
