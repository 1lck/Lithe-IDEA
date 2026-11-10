package workbench

import (
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// intp returns the address of one-based diff line n, as Core reports a side's line.
func intp(n int) *int { return &n }

func TestHunksOfGroupsDiffLinesIntoChanges(t *testing.T) {
	file := core.GitDiffFile{Lines: []core.GitDiffLine{
		{LineType: "context", Content: "a", OldLine: intp(1), NewLine: intp(1)},
		{LineType: "removed", Content: "b", OldLine: intp(2)},
		{LineType: "added", Content: "B", NewLine: intp(2)},
		{LineType: "context", Content: "c", OldLine: intp(3), NewLine: intp(3)},
		{LineType: "removed", Content: "d", OldLine: intp(4)},
		{LineType: "context", Content: "e", OldLine: intp(5), NewLine: intp(4)},
		{LineType: "added", Content: "f", NewLine: intp(5)},
		{LineType: "added", Content: "g", NewLine: intp(6)},
		{LineType: "context", Content: "h", OldLine: intp(6), NewLine: intp(7)},
	}}
	hunks := hunksOf(file)
	if len(hunks) != 3 {
		t.Fatalf("got %d changes, want 3: %+v", len(hunks), hunks)
	}
	modified := hunks[0]
	if modified.kind != editorview.GutterModified ||
		modified.change.OriginalStart != 2 || modified.change.OriginalEnd != 3 ||
		modified.change.ModifiedStart != 2 || modified.change.ModifiedEnd != 3 ||
		len(modified.change.OriginalLines) != 1 || modified.change.OriginalLines[0] != "b" ||
		len(modified.change.ModifiedLines) != 1 || modified.change.ModifiedLines[0] != "B" {
		t.Fatalf("modified change %+v", modified)
	}
	deleted := hunks[1]
	if deleted.kind != editorview.GutterDeleted ||
		deleted.change.OriginalStart != 4 || deleted.change.OriginalEnd != 5 ||
		deleted.change.ModifiedStart != 4 || deleted.change.ModifiedEnd != 4 ||
		len(deleted.change.ModifiedLines) != 0 {
		t.Fatalf("deleted change %+v", deleted)
	}
	added := hunks[2]
	if added.kind != editorview.GutterAdded ||
		added.change.ModifiedStart != 5 || added.change.ModifiedEnd != 7 ||
		added.change.OriginalStart != 6 || added.change.OriginalEnd != 6 {
		t.Fatalf("added change %+v", added)
	}
}

func TestHunkDecorationAndClickUseZeroBasedLines(t *testing.T) {
	hunks := []gitHunk{
		{kind: editorview.GutterModified, change: core.GutterChange{ModifiedStart: 3, ModifiedEnd: 5}},
		{kind: editorview.GutterDeleted, change: core.GutterChange{ModifiedStart: 8, ModifiedEnd: 8}},
	}
	if got := hunks[0].decoration(); got.StartLine != 2 || got.EndLine != 3 {
		t.Fatalf("modified decoration %+v", got)
	}
	if got := hunks[1].decoration(); got.StartLine != 7 || got.EndLine != 0 {
		t.Fatalf("deleted decoration %+v", got)
	}
	for _, tc := range []struct {
		line int
		kind editorview.GutterKind
		want int
	}{
		{2, editorview.GutterModified, 0},
		{3, editorview.GutterModified, 0},
		{4, editorview.GutterModified, -1},
		{7, editorview.GutterDeleted, 1},
		{7, editorview.GutterModified, -1},
	} {
		h, ok := gitHunkAt(hunks, tc.line, tc.kind)
		if tc.want < 0 {
			if ok {
				t.Fatalf("line %d of kind %v found %+v", tc.line, tc.kind, h)
			}
			continue
		}
		if !ok || h.kind != hunks[tc.want].kind ||
			h.change.ModifiedStart != hunks[tc.want].change.ModifiedStart ||
			h.change.ModifiedEnd != hunks[tc.want].change.ModifiedEnd {
			t.Fatalf("line %d of kind %v found %+v, want %+v", tc.line, tc.kind, h, hunks[tc.want])
		}
	}
}

func TestGitRelativePathRejectsOutsideTheRepository(t *testing.T) {
	root := "/work/repo"
	for _, tc := range []struct {
		file string
		want string
		ok   bool
	}{
		{"/work/repo/a/b.go", "a/b.go", true},
		{"/work/repo/a.go", "a.go", true},
		{"/work/repo", "", false},
		{"/work/other/a.go", "", false},
	} {
		got, ok := gitRelativePath(root, tc.file)
		if got != tc.want || ok != tc.ok {
			t.Errorf("gitRelativePath(%q) = %q, %v; want %q, %v", tc.file, got, ok, tc.want, tc.ok)
		}
	}
}

func TestRelativeGitTimeWordsTheAge(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		age  time.Duration
		want string
	}{
		{30 * time.Second, "just now"},
		{5 * time.Minute, "5 min ago"},
		{3 * time.Hour, "3 h ago"},
		{2 * 24 * time.Hour, "2 d ago"},
		{3 * 30 * 24 * time.Hour, "3 mo ago"},
		{2 * 365 * 24 * time.Hour, "2 y ago"},
	} {
		if got := relativeGitTime(i18n.English, now, now.Add(-tc.age)); got != tc.want {
			t.Errorf("age %v = %q, want %q", tc.age, got, tc.want)
		}
	}
}
