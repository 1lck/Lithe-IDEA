package workbench

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// referencesFixture is the tree of three usages in a.go (lines 0, 4, 9) and two in b.go (lines
// 2, 7), in the order a server could give them.
func referencesFixture() *referencesState {
	s := &referencesState{}
	files := []string{"a.go", "b.go", "a.go", "b.go", "a.go"}
	lines := []int{0, 2, 4, 7, 9}
	byFile := map[string]int{}
	for i, file := range files {
		s.targets = append(s.targets, locationAt(file, lines[i], 0))
		g, ok := byFile[file]
		if !ok {
			g = len(s.groups)
			byFile[file] = g
			s.groups = append(s.groups, newUsageGroup(file, file))
		}
		s.groups[g].indices = append(s.groups[g].indices, i)
		s.groupOf = append(s.groupOf, g)
	}
	s.layoutRows()
	s.selected = s.usageKey(0)
	return s
}

func TestReferencesTreeNestsUsagesUnderFiles(t *testing.T) {
	s := referencesFixture()
	want := []referenceRow{
		{kind: referenceRowRoot},
		{kind: referenceRowFile, group: 0},
		{kind: referenceRowUsage, group: 0, target: 0},
		{kind: referenceRowUsage, group: 0, target: 2},
		{kind: referenceRowUsage, group: 0, target: 4},
		{kind: referenceRowFile, group: 1},
		{kind: referenceRowUsage, group: 1, target: 1},
		{kind: referenceRowUsage, group: 1, target: 3},
	}
	if len(s.rows) != len(want) {
		t.Fatalf("rows = %+v", s.rows)
	}
	for i, row := range want {
		if s.rows[i] != row {
			t.Fatalf("row %d = %+v, want %+v", i, s.rows[i], row)
		}
		if s.rowOf(s.key(i)) != i {
			t.Fatalf("row %d does not keep its key %d", i, s.key(i))
		}
	}
	if n := s.node(0); n.Depth != 0 || !n.Branch || !n.Expanded {
		t.Fatalf("Usages node = %+v", n)
	}
	if n := s.node(5); n.Depth != 1 || !n.Branch || !n.Expanded {
		t.Fatalf("file node = %+v", n)
	}
	if n := s.node(2); n.Depth != 2 || n.Branch || !n.Selected {
		t.Fatalf("first usage = %+v, want a selected leaf", n)
	}
}

func TestClosingANodeHandsItTheSelectionOfAUsageUnderIt(t *testing.T) {
	s := referencesFixture()
	s.selected = s.usageKey(2)
	s.toggle(1)
	if len(s.rows) != 5 || s.selected != s.fileKey(0) {
		t.Fatalf("rows %d, selected %d after closing a.go", len(s.rows), s.selected)
	}
	// A usage the selection is not under keeps it.
	s.selected = s.usageKey(1)
	s.toggle(0)
	if len(s.rows) != 1 || s.selected != 0 {
		t.Fatalf("rows %d, selected %d after closing Usages", len(s.rows), s.selected)
	}
	s.toggle(0)
	if len(s.rows) != 5 || s.rowOf(s.fileKey(1)) != 2 {
		t.Fatalf("rows after opening Usages = %+v", s.rows)
	}
	// A usage row has nothing to open or close.
	s.selected = s.usageKey(1)
	s.toggle(s.rowOf(s.usageKey(1)))
	if len(s.rows) != 5 {
		t.Fatalf("toggling a usage changed the rows: %+v", s.rows)
	}
}

func TestCollapseAllKeepsTheFilesAndExpandAllShowsEveryUsage(t *testing.T) {
	s := referencesFixture()
	s.selected = s.usageKey(3)
	s.rootCollapsed = true
	s.setExpanded(false)
	if len(s.rows) != 3 || s.rows[1].kind != referenceRowFile || s.rows[2].kind != referenceRowFile {
		t.Fatalf("rows after collapse all = %+v", s.rows)
	}
	if s.selected != s.fileKey(1) || !s.reveal {
		t.Fatalf("selected %d, reveal %v; want b.go's node revealed", s.selected, s.reveal)
	}
	s.setExpanded(true)
	if len(s.rows) != 8 || s.selected != s.fileKey(1) {
		t.Fatalf("rows %d, selected %d after expand all", len(s.rows), s.selected)
	}
}

func TestStepTargetWalksUsagesInTreeOrderWithoutWrapping(t *testing.T) {
	s := referencesFixture()
	var order []int
	for target, ok := 0, true; ok; target, ok = s.stepTarget(true) {
		order = append(order, target)
		s.selectUsage(target)
	}
	if got := order; len(got) != 5 || got[0] != 0 || got[1] != 2 || got[2] != 4 || got[3] != 1 || got[4] != 3 {
		t.Fatalf("forward order = %v", got)
	}
	if _, ok := s.stepTarget(true); ok {
		t.Fatal("next went past the last usage")
	}
	if target, ok := s.stepTarget(false); !ok || target != 1 {
		t.Fatalf("previous of the last usage = %d %v", target, ok)
	}
	// From a node, next is its first usage and previous the usage before it, also under closed
	// nodes, which the step opens.
	s.groups[0].collapsed = true
	s.layoutRows()
	s.selected = s.fileKey(1)
	if target, ok := s.stepTarget(false); !ok || target != 4 {
		t.Fatalf("previous of b.go's node = %d %v", target, ok)
	}
	if target, ok := s.stepTarget(true); !ok || target != 1 {
		t.Fatalf("next of b.go's node = %d %v", target, ok)
	}
	s.selectUsage(4)
	if s.groups[0].collapsed || s.rowOf(s.usageKey(4)) != 4 {
		t.Fatalf("selecting a hidden usage did not open its file: %+v", s.rows)
	}
	s.selected = 0
	if _, ok := s.stepTarget(false); ok {
		t.Fatal("previous of the Usages node found a usage")
	}
	if target, ok := s.stepTarget(true); !ok || target != 0 {
		t.Fatalf("next of the Usages node = %d %v", target, ok)
	}
}

func TestShownTargetFollowsTheSelectedRow(t *testing.T) {
	s := referencesFixture()
	cases := []struct {
		selected, want int
	}{
		{0, 0},
		{s.fileKey(1), 1},
		{s.usageKey(3), 3},
	}
	for _, c := range cases {
		s.selected = c.selected
		if got, ok := s.shownTarget(); !ok || got != c.want {
			t.Fatalf("shown for key %d = %d %v, want %d", c.selected, got, ok, c.want)
		}
	}
	if _, ok := (&referencesState{}).shownTarget(); ok {
		t.Fatal("an empty answer showed a usage")
	}
}

func TestNewUsageGroupSplitsNameAndFolder(t *testing.T) {
	if g := newUsageGroup("/p/ui/absolute.go", "ui/absolute.go"); g.name != "absolute.go" || g.dir != "ui" {
		t.Fatalf("nested group = %+v", g)
	}
	if g := newUsageGroup("/p/main.go", "main.go"); g.name != "main.go" || g.dir != "" {
		t.Fatalf("root group = %+v", g)
	}
}

func usageText(line referenceLine) string {
	spans := utf16Spans(line.text, line.ranges)
	if len(spans) != 1 {
		return ""
	}
	return line.text[spans[0][0]:spans[0][1]]
}

func rangeOn(line, start, end int) core.PluginDocumentRange {
	return core.PluginDocumentRange{
		Start: core.PluginDocumentPosition{Line: line, UTF16Column: start},
		End:   core.PluginDocumentPosition{Line: line, UTF16Column: end},
	}
}

func TestReferenceLineDropsIndentationAndMarksTheUsage(t *testing.T) {
	line := referenceLineOf("\t\tabsSelf uint8 = 1 << 0\r", rangeOn(3, 2, 9))
	if line.text != "absSelf uint8 = 1 << 0" || usageText(line) != "absSelf" {
		t.Fatalf("line = %+v", line)
	}
	// A usage that runs onto the next line is marked to the end of this one.
	multi := referenceLineOf("x := call(", core.PluginDocumentRange{
		Start: core.PluginDocumentPosition{Line: 1, UTF16Column: 5},
		End:   core.PluginDocumentPosition{Line: 2, UTF16Column: 1},
	})
	if usageText(multi) != "call(" {
		t.Fatalf("multi-line usage = %+v", multi)
	}
}

func TestReferenceLineCountsUTF16AndCutsAFarUsage(t *testing.T) {
	// The emoji is two UTF-16 units, so the usage starts at unit 4.
	line := referenceLineOf("a😀 b := 1", rangeOn(0, 4, 5))
	if usageText(line) != "b" {
		t.Fatalf("usage after a surrogate pair = %+v", line)
	}
	far := strings.Repeat("x", 100) + " target"
	cut := referenceLineOf(far, rangeOn(0, 101, 107))
	if !strings.HasPrefix(cut.text, "…") || len(cut.text) >= len(far) || usageText(cut) != "target" {
		t.Fatalf("far usage = %+v", cut)
	}
	long := strings.Repeat("界", 200)
	bounded := referenceLineOf(long, rangeOn(0, 0, 1))
	if len(bounded.text) > referencePreviewWidth || !utf8.ValidString(bounded.text) || usageText(bounded) != "界" {
		t.Fatalf("long line = %d bytes, valid %v, usage %q", len(bounded.text), utf8.ValidString(bounded.text), usageText(bounded))
	}
}
