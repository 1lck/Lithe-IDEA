package workbench

import (
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// A folder holding repositories lists a node per repository in the Git Log's reference pane, each
// with its own sections, and a click on another repository's branch walks that branch there. The
// name after the filter chips lists the repositories: a second checked box merges both histories
// into one list by date, each commit in its repository's color, its details and its commit menu in
// its repository; unchecking a box walks the other repository alone again.
func TestWorkspaceLogWalksSeveralRepositoriesTogether(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	alphaID, betaID := repositoryID(t, p, "alpha"), repositoryID(t, p, "beta")
	h.app.layout.gitTab = gitTabLog
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.click(center(h.button(itemGit)))
	}
	h.settleUntil("alpha's history and beta's references", func() bool {
		_, read := p.nested.references[betaID]
		return p.logRepoID() == alphaID && !p.log.loading && len(p.log.graph.Rows) == 1 && read
	})
	h.settle()

	v := &h.app.logView
	for _, id := range []string{alphaID, betaID} {
		node := slices.IndexFunc(v.refItems, func(r logRefRow) bool { return r.kind == logRefRepository && r.repo == id })
		if node < 0 || node+1 >= len(v.refItems) || v.refItems[node+1].kind != logRefSection || v.refItems[node+1].depth != 1 {
			t.Fatalf("repository %q has no node with its own sections in %+v", id, v.refItems)
		}
	}
	foreign := slices.IndexFunc(v.refItems, func(r logRefRow) bool {
		return r.kind == logRefForeign && r.repo == betaID && r.short == "main"
	})
	if foreign < 0 {
		t.Fatalf("beta's node lists no main branch in %+v", v.refItems)
	}
	h.click(center(h.topHit(v.refs.RowID(foreign))))
	h.settleUntil("beta's main", func() bool {
		return p.logRepoID() == betaID && p.log.reference == "refs/heads/main" && !p.log.loading && len(p.log.graph.Rows) == 1
	})

	lang, g := h.app.language(), h.app.text.Git.Repositories
	h.click(center(h.hitLabeled(g.Choose)))
	if p.log.popover != logPopoverRoots {
		t.Fatalf("popover %v after clicking the repository name, want the repository list", p.log.popover)
	}
	toggle := func(name string) {
		t.Helper()
		label := i18n.SharedFormat(lang, "desktop.nested.rootToggle", map[string]string{"name": name})
		h.click(center(h.hitLabeled(label)))
	}
	toggle("alpha")
	h.settleUntil("both histories in one list", func() bool {
		return p.walksSeveral() && !p.log.loading && len(p.log.graph.Rows) == 2
	})
	if p.log.reference != "" {
		t.Fatalf("the merged list walks reference %q, want every repository's HEAD", p.log.reference)
	}
	for _, subject := range []string{"initial alpha", "initial beta"} {
		if !h.shows(subject) {
			t.Fatalf("the merged list does not show %q", subject)
		}
	}
	if !h.shows(g.Several(2)) {
		t.Fatalf("the name after the chips is not %q", g.Several(2))
	}
	betaRow := -1
	repos := map[string]bool{}
	for i, row := range p.log.graph.Rows {
		id := p.logCommitRepo(row.CommitHash)
		repos[id] = true
		if id == betaID {
			betaRow = i
		}
	}
	if !repos[alphaID] || !repos[betaID] || betaRow < 0 {
		t.Fatalf("the merged rows belong to %v, want alpha and beta", repos)
	}

	root, _, hashes := h.app.logMenuTarget(p, betaRow)
	if filepath.Base(root) != "beta" || len(hashes) != 1 {
		t.Fatalf("beta's commit menu acts on %v in %q, want its commit in beta", hashes, root)
	}
	if want := gitRun(t, filepath.Join(parent, "beta"), "rev-parse", "HEAD"); hashes[0] != want {
		t.Fatalf("beta's commit menu acts on %q, want beta's HEAD %q", hashes[0], want)
	}
	h.app.selectCommit(p, p.log.graph.Rows[betaRow].CommitHash)
	h.settleUntil("beta's commit files", func() bool { return p.log.filesState == logFilesReady })
	if len(p.log.files) != 1 || p.log.files[0].Path != "beta.txt" {
		t.Fatalf("beta's commit lists %+v, want beta.txt read from beta", p.log.files)
	}

	toggle("alpha")
	h.settleUntil("beta alone again", func() bool {
		return !p.walksSeveral() && p.logRepoID() == betaID && !p.log.loading && len(p.log.graph.Rows) == 1
	})
	if !h.shows("initial beta") || h.shows("initial alpha") {
		t.Fatal("after unchecking alpha the log does not show beta's history alone")
	}
}
