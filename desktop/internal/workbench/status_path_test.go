package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// statusPathValue is the accessible value of the navigation path the status bar showed in the
// last frame: the project and the crumbs after it, joined by slashes.
func (h *harness) statusPathValue() string {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleStatus && hit.Label == h.app.text.Status.Path {
			return hit.Value
		}
	}
	h.t.Fatal("the status bar shows no navigation path")
	return ""
}

// expectStatusPath paints what the last step did and fails unless the status bar's navigation
// path is then want.
func (h *harness) expectStatusPath(want string) {
	h.t.Helper()
	h.settle()
	if got := h.statusPathValue(); got != want {
		h.t.Fatalf("the status bar's path is %q, want %q", got, want)
	}
}

// statusPathFixture opens a project with src/main.go and notes.txt in the Project tool window.
func statusPathFixture(t *testing.T, h *harness) (p *project, source string) {
	t.Helper()
	root := t.TempDir()
	source = filepath.Join(root, "src", "main.go")
	if err := os.MkdirAll(filepath.Dir(source), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{source, filepath.Join(root, "notes.txt")} {
		if err := os.WriteFile(file, []byte("text\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	p = h.openTree(t, root)
	// A click leaves the pointer on the editor; ask for the hover at once instead of after the
	// pointer rests, so a step does not wait out the delay.
	h.app.semantics.hoverDelay = -1
	return p, source
}

// openStatusPathFile opens file in an editor and clicks into the editor.
func (h *harness) openStatusPathFile(p *project, file string) {
	h.t.Helper()
	h.app.openFile(p, file)
	h.settle()
	d := p.docs.byPath(file)
	if d == nil {
		h.t.Fatalf("%s did not open", filepath.Base(file))
	}
	h.press(h.topHit(d.hit))
}

// The path names the item of the area the user last clicked: the editor's file or the row
// selected in the Project tool window.
func TestStatusPathFollowsTheEditorAndTheProjectTree(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p, source := statusPathFixture(t, h)
	if got := h.statusPathValue(); got != p.name {
		t.Fatalf("with no file open the path is %q, want the project %q", got, p.name)
	}

	h.openStatusPathFile(p, source)
	h.expectStatusPath(p.name + "/src/main.go")
	for _, crumb := range []string{"src", "main.go"} {
		if !h.shows(crumb) {
			t.Fatalf("the path does not show the crumb %q", crumb)
		}
	}

	h.press(h.treeRowHit("src").Bounds)
	h.expectStatusPath(p.name + "/src")
	h.press(h.topHit(p.docs.byPath(source).hit))
	h.expectStatusPath(p.name + "/src/main.go")
	// A click on a file's row opens it in the preview tab; the path names the row.
	h.press(h.treeRowHit("notes.txt").Bounds)
	h.expectStatusPath(p.name + "/notes.txt")
	// The project's own row names the project alone; the click also closes it.
	h.press(h.treeRowHit(p.name).Bounds)
	h.expectStatusPath(p.name)
}

// Focus on a terminal, which has no item, keeps the path, and a file outside the project is
// named by its name alone.
func TestStatusPathKeepsItsItemAndNamesAFileOutsideTheProject(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p, source := statusPathFixture(t, h)
	h.openStatusPathFile(p, source)
	h.press(h.treeRowHit("src").Bounds)
	h.expectStatusPath(p.name + "/src")

	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.app.reduceChrome(core.SetChromeOpen(itemTerminal, true))
		h.settle()
	}
	if len(p.terms.list) != 1 {
		t.Fatalf("the Terminal tool window opened %d terminals", len(p.terms.list))
	}
	term := p.terms.list[0]
	h.app.focusTerminal(term.id)
	awaitDocumentState(t, h, func() bool { return term.view.Owns(h.driver.Snapshot().Focused) })
	if got := h.statusPathValue(); got != p.name+"/src" {
		t.Fatalf("with the terminal focused the path is %q, want the tree's row kept", got)
	}

	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(outside, []byte("text\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.openStatusPathFile(p, outside)
	h.expectStatusPath("outside.txt")
}

// In the Problems tool window the path names the file of the selected row: a diagnostic's file
// or a file's node.
func TestStatusPathFollowsTheProblemsSelection(t *testing.T) {
	h, a, _ := problemsTreeFixture(t)
	name := h.app.project.name
	h.clickNamed(problemsRowNamed(t, h, problemsDiagnosticRow(t, h, "note")))
	h.expectStatusPath(name + "/b.txt")
	h.clickNamed(problemsRowNamed(t, h, a))
	h.expectStatusPath(name + "/a.txt")
}

// A paint that names the same file as the paint before it makes no new strings.
func TestStatusPathReusesItsStringsWhileThePathStays(t *testing.T) {
	root := t.TempDir()
	a := &App{}
	p := &project{root: root, name: filepath.Base(root)}
	file := filepath.Join(root, "src", "main.go")
	if got := a.statusPathValue(p.name, a.statusFileCrumbs(p, file, "main.go")); got != p.name+"/src/main.go" {
		t.Fatalf("value = %q", got)
	}
	allocs := testing.AllocsPerRun(100, func() {
		a.statusPathValue(p.name, a.statusFileCrumbs(p, file, "main.go"))
	})
	if allocs != 0 {
		t.Fatalf("a paint of the same path allocated %v times", allocs)
	}
}
