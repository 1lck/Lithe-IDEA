package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// referencesFixture opens a project holding b.go and a.go and shows five usages in the order a
// server could give them: b.go lines 2 and 7, a.go lines 0, 4 and 9, interleaved. Core lays them
// out with the real kernel, so a.go comes first and each file's usages go by line.
func referencesFixture(t *testing.T) (*harness, *referencesState) {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	dir := t.TempDir()
	for name, text := range map[string]string{
		"a.go": "foo\n\tx\n\n\n\t\tbar := foo\n\n\n\n\n  baz(foo)\n",
		"b.go": "\n\n\tfoo()\n\n\n\n\n    x := foo()\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(dir)
	p := h.app.project
	files := []string{"b.go", "a.go", "b.go", "a.go", "a.go"}
	lines := []int{2, 0, 7, 4, 9}
	columns := []int{1, 0, 9, 9, 6}
	var targets []core.PluginSemanticLocation
	for i, file := range files {
		targets = append(targets, locationAt(filepath.Join(p.root, file), lines[i], columns[i]))
	}
	h.app.showReferences(p, targets, referenceQuery{}, "foo")
	return h, &h.app.editor.refs
}

// rowKeys is the keys of the visible rows.
func rowKeys(s *referencesState) []string {
	keys := make([]string, len(s.rows))
	for i, r := range s.rows {
		keys[i] = r.Key
	}
	return keys
}

func sameKeys(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

func TestReferencesTreeNestsUsagesUnderFilesInFileOrder(t *testing.T) {
	_, s := referencesFixture(t)
	a, b := "file:"+s.locations[1].FileKey, "file:"+s.locations[0].FileKey
	want := []string{"root", a, "usage:1", "usage:3", "usage:4", b, "usage:0", "usage:2"}
	if got := rowKeys(s); !sameKeys(got, want) {
		t.Fatalf("rows = %v, want %v", got, want)
	}
	if s.locations[0].DisplayPath != "b.go" || s.groups[0].Name != "a.go" || s.groups[0].Folder != "" {
		t.Fatalf("location %+v, first group %+v", s.locations[0], s.groups[0])
	}
	if s.groupOf[0] != 1 || s.groupOf[1] != 0 {
		t.Fatalf("groupOf = %v", s.groupOf)
	}
	// Every row keeps a distinct Tree key.
	seen := map[int]bool{}
	for i := range s.rows {
		if seen[s.key(i)] {
			t.Fatalf("row %d repeats key %d", i, s.key(i))
		}
		seen[s.key(i)] = true
	}
	if n := s.node(0); n.Depth != 0 || !n.Branch || !n.Expanded {
		t.Fatalf("Usages node = %+v", n)
	}
	if n := s.node(5); n.Depth != 1 || !n.Branch || !n.Expanded {
		t.Fatalf("file node = %+v", n)
	}
	if n := s.node(2); n.Depth != 2 || n.Branch || !n.Selected || s.selected != "usage:1" {
		t.Fatalf("first usage = %+v, selected %q; want a selected leaf", n, s.selected)
	}
}

func TestClosingANodeHandsItTheSelectionOfAUsageUnderIt(t *testing.T) {
	h, s := referencesFixture(t)
	a, b := "file:"+s.locations[1].FileKey, "file:"+s.locations[0].FileKey
	if !s.selectRow("usage:3") {
		t.Fatal("usage:3 does not show")
	}
	h.app.toggleReference(a)
	if len(s.rows) != 5 || s.selected != a || s.selectedRow != 1 {
		t.Fatalf("rows %v, selected %q at %d after closing a.go", rowKeys(s), s.selected, s.selectedRow)
	}
	// Closing the Usages node takes the selection of a file under it.
	s.selectRow(b)
	h.app.toggleReference("root")
	if len(s.rows) != 1 || s.selected != "root" {
		t.Fatalf("rows %v, selected %q after closing Usages", rowKeys(s), s.selected)
	}
	h.app.toggleReference("root")
	if len(s.rows) != 5 || s.rowOf(b) != 2 {
		t.Fatalf("rows after opening Usages = %v", rowKeys(s))
	}
	// A usage row has nothing to open or close.
	h.app.toggleReference("usage:0")
	if len(s.rows) != 5 {
		t.Fatalf("toggling a usage changed the rows: %v", rowKeys(s))
	}
}

func TestCollapseAllKeepsTheFilesAndExpandAllShowsEveryUsage(t *testing.T) {
	h, s := referencesFixture(t)
	b := "file:" + s.locations[0].FileKey
	s.selectRow("usage:2")
	h.app.toggleReference("root")
	h.app.expandReferences(false)
	if got := rowKeys(s); len(got) != 3 || s.rows[1].Kind != core.ReferenceRowFile || s.rows[2].Kind != core.ReferenceRowFile {
		t.Fatalf("rows after collapse all = %v", got)
	}
	// Closing Usages first moved the selection to it, so it stays there.
	if s.selected != "root" || !s.reveal {
		t.Fatalf("selected %q, reveal %v", s.selected, s.reveal)
	}
	s.selectRow(b)
	h.app.expandReferences(true)
	if len(s.rows) != 8 || s.selected != b {
		t.Fatalf("rows %d, selected %q after expand all", len(s.rows), s.selected)
	}
	s.selectRow("usage:2")
	h.app.expandReferences(false)
	if s.selected != b {
		t.Fatalf("collapse all left the selection on %q, want b.go's node", s.selected)
	}
}

func TestStepTargetWalksUsagesInTreeOrderWithoutWrapping(t *testing.T) {
	h, s := referencesFixture(t)
	b := "file:" + s.locations[0].FileKey
	var order []int
	for target, ok := s.shownTarget(); ok; target, ok = s.stepTarget(true) {
		order = append(order, target)
		h.app.selectUsage(target)
	}
	if want := []int{1, 3, 4, 0, 2}; len(order) != len(want) || order[0] != 1 || order[1] != 3 || order[2] != 4 || order[3] != 0 || order[4] != 2 {
		t.Fatalf("forward order = %v, want %v", order, want)
	}
	if _, ok := s.stepTarget(true); ok {
		t.Fatal("next went past the last usage")
	}
	if target, ok := s.stepTarget(false); !ok || target != 0 {
		t.Fatalf("previous of the last usage = %d %v", target, ok)
	}
	// From a node, next is its first usage and previous the usage before it, also under closed
	// nodes, which the step opens.
	h.app.toggleReference("file:" + s.locations[1].FileKey)
	s.selectRow(b)
	if target, ok := s.stepTarget(false); !ok || target != 4 {
		t.Fatalf("previous of b.go's node = %d %v", target, ok)
	}
	if target, ok := s.stepTarget(true); !ok || target != 0 {
		t.Fatalf("next of b.go's node = %d %v", target, ok)
	}
	h.app.selectUsage(4)
	if s.rowOf("usage:4") != 4 || s.selected != "usage:4" || !s.reveal {
		t.Fatalf("selecting a hidden usage did not open its file: %v, selected %q", rowKeys(s), s.selected)
	}
	s.selectRow("root")
	if _, ok := s.stepTarget(false); ok {
		t.Fatal("previous of the Usages node found a usage")
	}
	if target, ok := s.stepTarget(true); !ok || target != 1 {
		t.Fatalf("next of the Usages node = %d %v", target, ok)
	}
}

func TestShownTargetFollowsTheSelectedRow(t *testing.T) {
	_, s := referencesFixture(t)
	cases := []struct {
		key  string
		want int
	}{
		{"root", 1},
		{"file:" + s.locations[0].FileKey, 0},
		{"usage:4", 4},
	}
	for _, c := range cases {
		s.selectRow(c.key)
		if got, ok := s.shownTarget(); !ok || got != c.want {
			t.Fatalf("shown for %q = %d %v, want %d", c.key, got, ok, c.want)
		}
	}
	if _, ok := (&referencesState{selectedRow: -1}).shownTarget(); ok {
		t.Fatal("an empty answer showed a usage")
	}
}

func TestReferenceLinesComeFromCoreWithTheUsageMarked(t *testing.T) {
	h, s := referencesFixture(t)
	h.await("the usages' lines", func() bool { return s.lines[4].Text != "" })
	// Each row's line loses its indentation and keeps the usage marked in what is left.
	want := map[int]string{0: "foo()", 1: "foo", 2: "x := foo()", 3: "bar := foo", 4: "baz(foo)"}
	for i, text := range want {
		line := s.lines[i]
		spans := utf16Spans(line.Text, line.Ranges)
		if line.Text != text || len(spans) != 1 || line.Text[spans[0][0]:spans[0][1]] != "foo" {
			t.Fatalf("line %d = %+v, want %q with foo marked", i, line, text)
		}
	}
}

func TestReferenceLocationKeysFilesByPathAndOthersByURI(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "w")
	inside := referenceLocation(root, locationAt(filepath.Join(root, "ui", "absolute.go"), 3, 7))
	if inside.FileKey != filepath.Join(root, "ui", "absolute.go") || inside.DisplayPath != "ui/absolute.go" || inside.Line != 3 || inside.Column != 7 {
		t.Fatalf("file in the project = %+v", inside)
	}
	outsidePath := filepath.Join(string(filepath.Separator), "lib", "x.go")
	if outside := referenceLocation(root, locationAt(outsidePath, 0, 0)); outside.DisplayPath != filepath.ToSlash(outsidePath) {
		t.Fatalf("file outside the project = %+v", outside)
	}
	jar := "jar:file:///lib/rt.jar!/java/lang/String.class"
	if other := referenceLocation(root, core.PluginSemanticLocation{URI: jar}); other.FileKey != jar || other.DisplayPath != jar {
		t.Fatalf("location that is not a file = %+v", other)
	}
}

func TestReferenceLinesRequestSendsEachTextOnce(t *testing.T) {
	targets := []core.PluginSemanticLocation{
		locationAt("/w/a.go", 0, 0), locationAt("/w/a.go", 0, 4), locationAt("/w/b.go", 1, 2),
	}
	request, asked := referenceLinesRequest(targets, []string{"a = a", "a = a", ""}, []bool{true, true, false})
	if len(request.Texts) != 1 || len(request.Usages) != 2 || len(asked) != 2 || asked[1] != 1 {
		t.Fatalf("request %+v, asked %v", request, asked)
	}
	if u := request.Usages[1]; u.Text != 0 || u.Column != 4 || u.EndColumn != 7 {
		t.Fatalf("second usage = %+v", u)
	}
}
