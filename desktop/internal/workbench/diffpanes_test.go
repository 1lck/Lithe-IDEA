package workbench

import (
	"math"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
)

// paneLine makes a line of Core's unified diff; an old or a new number of 0 stands for none.
func paneLine(kind string, oldNo, newNo int, text string) core.GitDiffLine {
	line := core.GitDiffLine{LineType: kind, Content: text}
	if oldNo != 0 {
		line.OldLine = &oldNo
	}
	if newNo != 0 {
		line.NewLine = &newNo
	}
	return line
}

// paneLines is the lines of a pane's text.
func paneLines(p diffPane) []string { return strings.Split(string(p.text), "\n") }

// paneJoin joins runs of lines into one.
func paneJoin(runs ...[]core.GitDiffLine) []core.GitDiffLine {
	var out []core.GitDiffLine
	for _, run := range runs {
		out = append(out, run...)
	}
	return out
}

// paneContext makes count unchanged lines that start at the old number oldFrom and the new
// number newFrom; the text of a line is "c" and its new number.
func paneContext(oldFrom, newFrom, count int) []core.GitDiffLine {
	out := make([]core.GitDiffLine, 0, count)
	for k := 0; k < count; k++ {
		out = append(out, paneLine("context", oldFrom+k, newFrom+k, "c"+strconv.Itoa(newFrom+k)))
	}
	return out
}

// paneFoldText is the note of a fold in these tests.
func paneFoldText(hidden int) string { return "fold " + strconv.Itoa(hidden) }

// paneSample is a hunk from the top of a file: one line replaced by two, in unchanged lines.
func paneSample() []core.GitDiffLine {
	return []core.GitDiffLine{
		paneLine("header", 0, 0, "@@ -1,4 +1,4 @@"),
		paneLine("context", 1, 1, "a"),
		paneLine("removed", 2, 0, "b"),
		paneLine("added", 0, 2, "B"),
		paneLine("added", 0, 3, "C"),
		paneLine("context", 3, 4, "d"),
	}
}

// paneFoldLines is a file of 20 unchanged lines, a change that replaces two lines with one,
// and 20 unchanged lines. Unified indices: the header is 0, the first run is 1 to 20, the
// change is 21 to 23 and the last run is 24 to 43.
func paneFoldLines() []core.GitDiffLine {
	return paneJoin(
		[]core.GitDiffLine{paneLine("header", 0, 0, "@@ -1,42 +1,41 @@")},
		paneContext(1, 1, 20),
		[]core.GitDiffLine{
			paneLine("removed", 21, 0, "x1"),
			paneLine("removed", 22, 0, "x2"),
			paneLine("added", 0, 21, "y"),
		},
		paneContext(23, 22, 20),
	)
}

// wantPane checks the lines and the gutter labels of a pane.
func wantPane(t *testing.T, name string, p diffPane, lines, labels []string) {
	t.Helper()
	if got := paneLines(p); !reflect.DeepEqual(got, lines) {
		t.Errorf("%s pane lines = %q, want %q", name, got, lines)
	}
	if !reflect.DeepEqual(p.labels, labels) {
		t.Errorf("%s pane labels = %q, want %q", name, p.labels, labels)
	}
	if p.lineCount() != len(labels) {
		t.Errorf("%s pane lineCount = %d, want %d", name, p.lineCount(), len(labels))
	}
}

// wantMarks checks the marks of a pane.
func wantMarks(t *testing.T, name string, got, want []diffMark) {
	t.Helper()
	if len(got) != len(want) || (len(want) > 0 && !reflect.DeepEqual(got, want)) {
		t.Errorf("%s pane marks = %+v, want %+v", name, got, want)
	}
}

// wantNotes checks the notes of a pane, given by line and text: every note stands for a fold or
// a hunk separator, so each carries the icon of unfolding and a rule.
func wantNotes(t *testing.T, name string, got, want []editorview.LineAnnotation) {
	t.Helper()
	want = slices.Clone(want)
	for i := range want {
		want[i].Icon, want[i].Rule = icons.UnfoldVertical, true
	}
	if len(got) != len(want) || (len(want) > 0 && !reflect.DeepEqual(got, want)) {
		t.Errorf("%s pane notes = %+v, want %+v", name, got, want)
	}
}

// wantFragments checks the fragments of a layout.
func wantFragments(t *testing.T, got, want []diffFragment) {
	t.Helper()
	if len(got) != len(want) || (len(want) > 0 && !reflect.DeepEqual(got, want)) {
		t.Errorf("fragments = %+v, want %+v", got, want)
	}
}

// wantFolds checks the folds of a layout.
func wantFolds(t *testing.T, got, want []diffFold) {
	t.Helper()
	if len(got) != len(want) || (len(want) > 0 && !reflect.DeepEqual(got, want)) {
		t.Errorf("folds = %+v, want %+v", got, want)
	}
}

func TestDiffPanesSplitWhole(t *testing.T) {
	l := layoutDiff(paneSample(), nil, true, true, nil, paneFoldText)
	if !l.split {
		t.Fatal("split layout reports split = false")
	}
	wantPane(t, "before", l.before, []string{"a", "b", "d"}, []string{"1", "2", "3"})
	wantPane(t, "after", l.after, []string{"a", "B", "C", "d"}, []string{"1", "2", "3", "4"})
	wantFragments(t, l.fragments, []diffFragment{
		{before: diffSpan{1, 2}, after: diffSpan{1, 3}, kind: diffModified},
	})
	wantMarks(t, "before", l.before.marks, []diffMark{{span: diffSpan{1, 2}, kind: diffModified}})
	wantMarks(t, "after", l.after.marks, []diffMark{{span: diffSpan{1, 3}, kind: diffModified}})
	wantNotes(t, "before", l.before.notes, nil)
	wantNotes(t, "after", l.after.notes, nil)
	wantFolds(t, l.folds, nil)
}

func TestDiffPanesSplitInsertionAndDeletion(t *testing.T) {
	t.Run("insertion", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("context", 1, 1, "a"),
			paneLine("added", 0, 2, "x"),
			paneLine("added", 0, 3, "y"),
			paneLine("context", 2, 4, "b"),
		}, nil, true, true, nil, paneFoldText)
		wantPane(t, "before", l.before, []string{"a", "b"}, []string{"1", "2"})
		wantPane(t, "after", l.after, []string{"a", "x", "y", "b"}, []string{"1", "2", "3", "4"})
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{1, 1}, after: diffSpan{1, 3}, kind: diffAdded},
		})
		wantMarks(t, "before", l.before.marks, []diffMark{{span: diffSpan{1, 1}, kind: diffAdded, boundary: true}})
		wantMarks(t, "after", l.after.marks, []diffMark{{span: diffSpan{1, 3}, kind: diffAdded}})
	})
	t.Run("deletion", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("context", 1, 1, "a"),
			paneLine("removed", 2, 0, "x"),
			paneLine("removed", 3, 0, "y"),
			paneLine("context", 4, 2, "b"),
		}, nil, true, true, nil, paneFoldText)
		wantPane(t, "before", l.before, []string{"a", "x", "y", "b"}, []string{"1", "2", "3", "4"})
		wantPane(t, "after", l.after, []string{"a", "b"}, []string{"1", "2"})
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{1, 3}, after: diffSpan{1, 1}, kind: diffRemoved},
		})
		wantMarks(t, "before", l.before.marks, []diffMark{{span: diffSpan{1, 3}, kind: diffRemoved}})
		wantMarks(t, "after", l.after.marks, []diffMark{{span: diffSpan{1, 1}, kind: diffRemoved, boundary: true}})
	})
	t.Run("new file", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("header", 0, 0, "@@ -0,0 +1,2 @@"),
			paneLine("added", 0, 1, "x"),
			paneLine("added", 0, 2, "y"),
		}, nil, true, false, nil, paneFoldText)
		if string(l.before.text) != "" || !reflect.DeepEqual(l.before.labels, []string{""}) {
			t.Errorf("before pane of a new file = %q %q, want one empty line", l.before.text, l.before.labels)
		}
		wantPane(t, "after", l.after, []string{"x", "y"}, []string{"1", "2"})
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{0, 0}, after: diffSpan{0, 2}, kind: diffAdded},
		})
		wantMarks(t, "before", l.before.marks, []diffMark{{span: diffSpan{0, 0}, kind: diffAdded, boundary: true}})
	})
}

func TestDiffPanesBlocks(t *testing.T) {
	lines := []core.GitDiffLine{
		paneLine("context", 1, 1, "a"),
		paneLine("removed", 2, 0, "b"),
		paneLine("added", 0, 2, "B"),
		paneLine("context", 3, 3, "c"),
		paneLine("added", 0, 4, "D"),
		paneLine("context", 4, 5, "e"),
		paneLine("removed", 5, 0, "f"),
		paneLine("context", 6, 6, "g"),
	}
	first, second := &core.DiffBlock{ID: "first"}, &core.DiffBlock{ID: "second"}
	for _, split := range []bool{true, false} {
		name := "unified"
		if split {
			name = "split"
		}
		t.Run(name, func(t *testing.T) {
			l := layoutDiff(lines, map[int]*core.DiffBlock{1: first, 4: second}, split, true, nil, paneFoldText)
			if len(l.fragments) != 3 {
				t.Fatalf("fragments = %d, want 3", len(l.fragments))
			}
			want := []struct {
				block  *core.DiffBlock
				number int
			}{{first, 1}, {second, 2}, {nil, 0}}
			for k, w := range want {
				if got := l.fragments[k]; got.block != w.block || got.number != w.number {
					t.Errorf("fragment %d has block %p number %d, want block %p number %d", k, got.block, got.number, w.block, w.number)
				}
			}
		})
	}

	// A block anchored on a later line of its run still names the run.
	l := layoutDiff(lines, map[int]*core.DiffBlock{2: first}, true, true, nil, paneFoldText)
	if got := l.fragments[0]; got.block != first || got.number != 1 {
		t.Errorf("run anchored on its second line has block %p number %d, want block %p number 1", got.block, got.number, first)
	}
	if got := l.fragments[1]; got.block != nil || got.number != 0 {
		t.Errorf("run without an anchor has block %p number %d, want nil and 0", got.block, got.number)
	}
}

func TestDiffPanesFolding(t *testing.T) {
	l := layoutDiff(paneFoldLines(), nil, true, false, nil, paneFoldText)
	wantPane(t, "before", l.before,
		[]string{"", "c18", "c19", "c20", "x1", "x2", "c22", "c23", "c24", ""},
		[]string{"", "18", "19", "20", "21", "22", "23", "24", "25", ""})
	wantPane(t, "after", l.after,
		[]string{"", "c18", "c19", "c20", "y", "c22", "c23", "c24", ""},
		[]string{"", "18", "19", "20", "21", "22", "23", "24", ""})
	wantFolds(t, l.folds, []diffFold{
		{before: 0, after: 0, at: 1, hidden: 17},
		{before: 9, after: 8, at: 24, hidden: 17},
	})
	wantNotes(t, "before", l.before.notes, []editorview.LineAnnotation{{Line: 0, Text: "fold 17"}, {Line: 9, Text: "fold 17"}})
	wantNotes(t, "after", l.after.notes, []editorview.LineAnnotation{{Line: 0, Text: "fold 17"}, {Line: 8, Text: "fold 17"}})
	wantMarks(t, "before", l.before.marks, []diffMark{
		{span: diffSpan{0, 1}, kind: diffFolded},
		{span: diffSpan{4, 6}, kind: diffModified},
		{span: diffSpan{9, 10}, kind: diffFolded},
	})
	wantMarks(t, "after", l.after.marks, []diffMark{
		{span: diffSpan{0, 1}, kind: diffFolded},
		{span: diffSpan{4, 5}, kind: diffModified},
		{span: diffSpan{8, 9}, kind: diffFolded},
	})
	wantFragments(t, l.fragments, []diffFragment{
		{before: diffSpan{4, 6}, after: diffSpan{4, 5}, kind: diffModified},
	})

	t.Run("expanded", func(t *testing.T) {
		l := layoutDiff(paneFoldLines(), nil, true, false, map[int]bool{1: true}, paneFoldText)
		wantFolds(t, l.folds, []diffFold{{before: 25, after: 24, at: 24, hidden: 17}})
		if got := paneLines(l.before); len(got) != 26 || got[0] != "c1" || got[19] != "c20" || got[20] != "x1" || got[25] != "" {
			t.Errorf("before pane after opening the first fold = %q, want c1..c20, x1, x2, c22..c24 and a placeholder", got)
		}
		if got := paneLines(l.after); len(got) != 25 || got[0] != "c1" || got[19] != "c20" || got[20] != "y" || got[24] != "" {
			t.Errorf("after pane after opening the first fold = %q, want c1..c20, y, c22..c24 and a placeholder", got)
		}
		if got := l.before.labels[0]; got != "1" {
			t.Errorf("first label after opening the first fold = %q, want 1", got)
		}
	})

	t.Run("whole", func(t *testing.T) {
		l := layoutDiff(paneFoldLines(), nil, true, true, nil, paneFoldText)
		wantFolds(t, l.folds, nil)
		if got := l.before.lineCount(); got != 42 {
			t.Errorf("before pane of the whole file has %d lines, want 42", got)
		}
		if got := l.after.lineCount(); got != 41 {
			t.Errorf("after pane of the whole file has %d lines, want 41", got)
		}
	})

	t.Run("short runs stay", func(t *testing.T) {
		for _, tc := range []struct {
			run    int
			folded bool
		}{{9, false}, {10, true}} {
			lines := paneJoin(
				[]core.GitDiffLine{paneLine("added", 0, 1, "n1")},
				paneContext(1, 2, tc.run),
				[]core.GitDiffLine{paneLine("added", 0, tc.run+2, "n2")},
			)
			l := layoutDiff(lines, nil, true, false, nil, paneFoldText)
			if !tc.folded {
				wantFolds(t, l.folds, nil)
				if l.before.lineCount() != 9 || l.after.lineCount() != 11 {
					t.Errorf("run of %d: panes have %d and %d lines, want 9 and 11", tc.run, l.before.lineCount(), l.after.lineCount())
				}
				continue
			}
			wantFolds(t, l.folds, []diffFold{{before: 3, after: 4, at: 1, hidden: 4}})
			if l.before.lineCount() != 7 || l.after.lineCount() != 9 {
				t.Errorf("run of %d: panes have %d and %d lines, want 7 and 9", tc.run, l.before.lineCount(), l.after.lineCount())
			}
			wantPane(t, "before", l.before,
				[]string{"c2", "c3", "c4", "", "c9", "c10", "c11"},
				[]string{"1", "2", "3", "", "8", "9", "10"})
		}
	})
}

func TestDiffPanesSeparator(t *testing.T) {
	lines := []core.GitDiffLine{
		paneLine("header", 0, 0, "@@ -1,2 +1,2 @@"),
		paneLine("context", 1, 1, "a"),
		paneLine("context", 2, 2, "b"),
		paneLine("header", 0, 0, "@@ -40,3 +41,3 @@"),
		paneLine("context", 40, 41, "x"),
		paneLine("removed", 41, 0, "y"),
		paneLine("added", 0, 42, "Y"),
	}
	l := layoutDiff(lines, nil, true, false, nil, paneFoldText)
	wantPane(t, "before", l.before, []string{"a", "b", "", "x", "y"}, []string{"1", "2", "", "40", "41"})
	wantPane(t, "after", l.after, []string{"a", "b", "", "x", "Y"}, []string{"1", "2", "", "41", "42"})
	note := []editorview.LineAnnotation{{Line: 2, Text: "@@ -40,3 +41,3 @@"}}
	wantNotes(t, "before", l.before.notes, note)
	wantNotes(t, "after", l.after.notes, note)
	wantMarks(t, "before", l.before.marks, []diffMark{
		{span: diffSpan{2, 3}, kind: diffFolded},
		{span: diffSpan{4, 5}, kind: diffModified},
	})
	wantMarks(t, "after", l.after.marks, []diffMark{
		{span: diffSpan{2, 3}, kind: diffFolded},
		{span: diffSpan{4, 5}, kind: diffModified},
	})
	wantFolds(t, l.folds, nil)
	wantFragments(t, l.fragments, []diffFragment{
		{before: diffSpan{4, 5}, after: diffSpan{4, 5}, kind: diffModified},
	})

	t.Run("first header kept", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("header", 0, 0, "@@ -10,2 +10,2 @@"),
			paneLine("context", 10, 10, "a"),
			paneLine("context", 11, 11, "b"),
		}, nil, true, true, nil, paneFoldText)
		wantPane(t, "before", l.before, []string{"", "a", "b"}, []string{"", "10", "11"})
		wantPane(t, "after", l.after, []string{"", "a", "b"}, []string{"", "10", "11"})
		wantNotes(t, "before", l.before.notes, []editorview.LineAnnotation{{Line: 0, Text: "@@ -10,2 +10,2 @@"}})
		wantMarks(t, "after", l.after.marks, []diffMark{{span: diffSpan{0, 1}, kind: diffFolded}})
		wantFolds(t, l.folds, nil)
		wantFragments(t, l.fragments, nil)
	})
}

func TestDiffPanesUnified(t *testing.T) {
	lines := []core.GitDiffLine{
		paneLine("header", 0, 0, "@@ -8,4 +9,4 @@"),
		paneLine("context", 9, 10, "a"),
		paneLine("removed", 10, 0, "b"),
		paneLine("removed", 11, 0, "c"),
		paneLine("added", 0, 11, "B"),
		paneLine("context", 12, 12, "d"),
	}
	l := layoutDiff(lines, nil, false, true, nil, paneFoldText)
	if l.split {
		t.Error("unified layout reports split = true")
	}
	if !reflect.DeepEqual(l.before, diffPane{}) {
		t.Errorf("before pane of a unified layout = %+v, want the zero value", l.before)
	}
	wantPane(t, "after", l.after,
		[]string{"", "a", "b", "c", "B", "d"},
		[]string{"", " 9 10", "10   ", "11   ", "   11", "12 12"})
	wantMarks(t, "after", l.after.marks, []diffMark{
		{span: diffSpan{0, 1}, kind: diffFolded},
		{span: diffSpan{2, 4}, kind: diffRemoved},
		{span: diffSpan{4, 5}, kind: diffAdded},
	})
	wantNotes(t, "after", l.after.notes, []editorview.LineAnnotation{{Line: 0, Text: "@@ -8,4 +9,4 @@"}})
	wantFragments(t, l.fragments, []diffFragment{
		{before: diffSpan{2, 5}, after: diffSpan{2, 5}, kind: diffModified},
	})

	t.Run("mixed run", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("removed", 1, 0, "a"),
			paneLine("removed", 2, 0, "b"),
			paneLine("added", 0, 1, "c"),
			paneLine("added", 0, 2, "d"),
			paneLine("removed", 3, 0, "e"),
		}, nil, false, true, nil, paneFoldText)
		wantPane(t, "after", l.after, []string{"a", "b", "c", "d", "e"}, []string{"1  ", "2  ", "  1", "  2", "3  "})
		wantMarks(t, "after", l.after.marks, []diffMark{
			{span: diffSpan{0, 2}, kind: diffRemoved},
			{span: diffSpan{2, 4}, kind: diffAdded},
			{span: diffSpan{4, 5}, kind: diffRemoved},
		})
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{0, 5}, after: diffSpan{0, 5}, kind: diffModified},
		})
	})

	t.Run("pure runs", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("context", 1, 1, "a"),
			paneLine("added", 0, 2, "b"),
			paneLine("context", 2, 3, "c"),
			paneLine("removed", 3, 0, "d"),
		}, nil, false, true, nil, paneFoldText)
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{1, 2}, after: diffSpan{1, 2}, kind: diffAdded},
			{before: diffSpan{3, 4}, after: diffSpan{3, 4}, kind: diffRemoved},
		})
	})

	t.Run("folds", func(t *testing.T) {
		l := layoutDiff(paneFoldLines(), nil, false, false, nil, paneFoldText)
		wantPane(t, "after", l.after,
			[]string{"", "c18", "c19", "c20", "x1", "x2", "y", "c22", "c23", "c24", ""},
			[]string{"", "18 18", "19 19", "20 20", "21   ", "22   ", "   21", "23 22", "24 23", "25 24", ""})
		wantFolds(t, l.folds, []diffFold{
			{before: 0, after: 0, at: 1, hidden: 17},
			{before: 10, after: 10, at: 24, hidden: 17},
		})
		wantNotes(t, "after", l.after.notes, []editorview.LineAnnotation{{Line: 0, Text: "fold 17"}, {Line: 10, Text: "fold 17"}})
		wantMarks(t, "after", l.after.marks, []diffMark{
			{span: diffSpan{0, 1}, kind: diffFolded},
			{span: diffSpan{4, 6}, kind: diffRemoved},
			{span: diffSpan{6, 7}, kind: diffAdded},
			{span: diffSpan{10, 11}, kind: diffFolded},
		})
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{4, 7}, after: diffSpan{4, 7}, kind: diffModified},
		})
	})
}

func TestDiffPanesEmptyAndUnknown(t *testing.T) {
	for _, split := range []bool{true, false} {
		l := layoutDiff(nil, nil, split, false, nil, paneFoldText)
		if string(l.after.text) != "" || !reflect.DeepEqual(l.after.labels, []string{""}) {
			t.Errorf("split=%v: after pane of an empty diff = %q %q, want one empty line", split, l.after.text, l.after.labels)
		}
		if split && (string(l.before.text) != "" || !reflect.DeepEqual(l.before.labels, []string{""})) {
			t.Errorf("before pane of an empty diff = %q %q, want one empty line", l.before.text, l.before.labels)
		}
		if len(l.fragments) != 0 || len(l.folds) != 0 {
			t.Errorf("split=%v: empty diff has %d fragments and %d folds, want none", split, len(l.fragments), len(l.folds))
		}
	}

	l := layoutDiff([]core.GitDiffLine{
		paneLine("context", 1, 1, "a"),
		paneLine("binary", 0, 0, "ignored"),
		paneLine("context", 2, 2, "b"),
	}, nil, true, true, nil, paneFoldText)
	wantPane(t, "before", l.before, []string{"a", "b"}, []string{"1", "2"})
	wantPane(t, "after", l.after, []string{"a", "b"}, []string{"1", "2"})
}

func TestDiffPanesMapLine(t *testing.T) {
	near := func(got, want float64) bool { return math.Abs(got-want) < 1e-9 }
	check := func(t *testing.T, l *diffLayout, y float64, fromBefore bool, want float64) {
		t.Helper()
		if got := l.mapLine(y, fromBefore); !near(got, want) {
			t.Errorf("mapLine(%v, fromBefore=%v) = %v, want %v", y, fromBefore, got, want)
		}
	}

	t.Run("replacement", func(t *testing.T) {
		l := layoutDiff(paneSample(), nil, true, true, nil, paneFoldText)
		check(t, l, 0.5, true, 0.5)
		check(t, l, 1.5, true, 2)
		check(t, l, 2.5, true, 3.5)
		check(t, l, 2, false, 1.5)
		check(t, l, 3.5, false, 2.5)
	})

	t.Run("insertion", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("context", 1, 1, "a"),
			paneLine("added", 0, 2, "x"),
			paneLine("added", 0, 3, "y"),
			paneLine("added", 0, 4, "z"),
			paneLine("context", 2, 5, "d"),
		}, nil, true, true, nil, paneFoldText)
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{1, 1}, after: diffSpan{1, 4}, kind: diffAdded},
		})
		check(t, l, 1.0, true, 4.0)
		check(t, l, 2.5, false, 1.0)
		check(t, l, 0.5, true, 0.5)
		check(t, l, 1.5, true, 4.5)
		check(t, l, 4.5, false, 1.5)
	})

	t.Run("two changes", func(t *testing.T) {
		l := layoutDiff([]core.GitDiffLine{
			paneLine("context", 1, 1, "a"),
			paneLine("removed", 2, 0, "b"),
			paneLine("added", 0, 2, "B"),
			paneLine("added", 0, 3, "C"),
			paneLine("context", 3, 4, "d"),
			paneLine("removed", 4, 0, "e"),
			paneLine("context", 5, 5, "f"),
		}, nil, true, true, nil, paneFoldText)
		wantFragments(t, l.fragments, []diffFragment{
			{before: diffSpan{1, 2}, after: diffSpan{1, 3}, kind: diffModified},
			{before: diffSpan{3, 4}, after: diffSpan{4, 4}, kind: diffRemoved},
		})
		check(t, l, 2.5, true, 3.5)
		check(t, l, 3.5, true, 4)
		check(t, l, 4.5, true, 4.5)
		check(t, l, 3.5, false, 2.5)
		check(t, l, 4, false, 4)
	})

	t.Run("unified", func(t *testing.T) {
		l := layoutDiff(paneSample(), nil, false, true, nil, paneFoldText)
		check(t, l, 2.5, true, 2.5)
		check(t, l, 2.5, false, 2.5)
	})
}

func TestDiffPanesFoldAt(t *testing.T) {
	l := layoutDiff(paneFoldLines(), nil, true, false, nil, paneFoldText)
	first := diffFold{before: 0, after: 0, at: 1, hidden: 17}
	second := diffFold{before: 9, after: 8, at: 24, hidden: 17}
	for _, tc := range []struct {
		line   int
		before bool
		want   diffFold
		found  bool
	}{
		{0, true, first, true},
		{0, false, first, true},
		{9, true, second, true},
		{8, false, second, true},
		{8, true, diffFold{}, false},
		{9, false, diffFold{}, false},
		{4, true, diffFold{}, false},
		{4, false, diffFold{}, false},
		{-1, true, diffFold{}, false},
		{100, false, diffFold{}, false},
	} {
		got, ok := l.foldAt(tc.line, tc.before)
		if ok != tc.found || got != tc.want {
			t.Errorf("foldAt(%d, before=%v) = %+v, %v; want %+v, %v", tc.line, tc.before, got, ok, tc.want, tc.found)
		}
	}

	none := layoutDiff(paneSample(), nil, true, true, nil, paneFoldText)
	if got, ok := none.foldAt(0, true); ok {
		t.Errorf("foldAt on a layout without folds = %+v, true; want false", got)
	}
}
