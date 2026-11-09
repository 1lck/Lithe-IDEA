package editorview

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/gfx"
)

// recordEdits makes each of edits to v, which must be a view nothing was done to yet, and
// returns the text before the first and after each one: texts[i] is the text undoing back to
// step i must give. after runs once each edit has changed the text, for a test that reads the
// view between edits. Every edit must be one undo step.
func recordEdits(t *testing.T, v *View, after func(), edits ...func(v *View)) []string {
	t.Helper()
	texts := []string{v.contents()}
	for i, edit := range edits {
		edit(v)
		text := v.contents()
		if text == texts[len(texts)-1] {
			t.Fatalf("edit %d left the text as it was", i+1)
		}
		texts = append(texts, text)
		if after != nil {
			after()
		}
	}
	if len(v.undo) != len(edits) {
		t.Fatalf("%d edits made %d undo steps, want one each", len(edits), len(v.undo))
	}
	return texts
}

// walkHistory undoes every step of v one by one and then redoes every one, texts being what
// recordEdits returned. After each step it checks the text is the one the step leaves and calls
// check with a name for the step.
func walkHistory(t *testing.T, v *View, texts []string, check func(at string)) {
	t.Helper()
	for i := len(texts) - 1; i > 0; i-- {
		if !v.Undo() {
			t.Fatalf("there was no edit %d to undo", i)
		}
		if got := v.contents(); got != texts[i-1] {
			t.Fatalf("undoing edit %d left %d bytes, want the %d bytes before it", i, len(got), len(texts[i-1]))
		}
		check(fmt.Sprintf("undoing edit %d", i))
	}
	for i := 1; i < len(texts); i++ {
		if !v.Redo() {
			t.Fatalf("there was no edit %d to redo", i)
		}
		if got := v.contents(); got != texts[i] {
			t.Fatalf("redoing edit %d left %d bytes, want the %d it makes", i, len(got), len(texts[i]))
		}
		check(fmt.Sprintf("redoing edit %d", i))
	}
	if v.Redo() {
		t.Fatal("redoing every edit left another one to redo")
	}
}

// colorTimeout is how long a test waits for the highlighter to catch up before it says it never
// will. A highlighter that is right is done in milliseconds; the wait only ends the test of one
// that is wrong.
const colorTimeout = 5 * time.Second

// undoWarmup has what undoSource and its edits make the Go grammar match, so that the grammar's
// patterns compile before the view under test is made: compiling them inside the view's own
// highlighter could take longer than the time it gives a line.
const undoWarmup = "package warm\n\nimport (\n\t\"fmt\"\n)\n\n/* block\ncomment */\n" +
	"var table = map[string]int{\n\t\"one\": 1, // pair\n}\n\n" +
	"// Warm adds and says so.\nfunc Warm(x int) string {\n\ty := x + 3 // the sum\n\ts := `raw 世界`\n" +
	"\tfor i := 0; i < 3; i++ {\n\t\ty += i\n\t}\n\treturn fmt.Sprint(y) + s + \"sum 1\"\n}\n"

// undoSource is Go source of about ninety lines: a header and twelve small functions, each with
// a comment, a number and a string. It is short enough that the highlighter never has to guess
// the state a line starts in, which would make its colors depend on the order they were asked in.
func undoSource() string {
	var b strings.Builder
	b.WriteString("package sample\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\n")
	for i := 1; i <= 12; i++ {
		fmt.Fprintf(&b, "// add%[1]d adds %[1]d and says so.\nfunc add%[1]d(x int) string {\n\ty := x + %[1]d // the sum\n"+
			"\ts := \"sum %[1]d\"\n\treturn fmt.Sprint(y) + strings.ToUpper(s)\n}\n\n", i)
	}
	return b.String()
}

// colorWatch is a view of Go source and what a highlighter that read the view's text in one
// pass colors each line, which the view's colors must be once its highlighter has caught up.
type colorWatch struct {
	t   *testing.T
	v   *View
	syn *syntax.Syntax
	// woken holds a signal when the view's highlighter colored lines anew, as the window would
	// be woken to paint them.
	woken chan struct{}
	// fresh is the colors of every text the test has asked about.
	fresh map[string][][]syntax.Token
}

// newColorWatch opens a view of the Go source text.
func newColorWatch(t *testing.T, text string) *colorWatch {
	t.Helper()
	syn := benchRegistry().Syntax("go")
	if syn == nil {
		t.Fatal("there is no Go syntax to color with")
	}
	w := &colorWatch{t: t, syn: syn, woken: make(chan struct{}, 1), fresh: make(map[string][][]syntax.Token)}
	w.expected(undoWarmup)
	notify := func() {
		select {
		case w.woken <- struct{}{}:
		default:
		}
	}
	w.v = New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte(text)), Syntax: syn, Notify: notify})
	t.Cleanup(w.v.Close)
	return w
}

// readColors is the tokens of each of the first lines lines of h's text.
func readColors(h *syntax.Highlighter, lines int) [][]syntax.Token {
	h.Prepare(0, lines-1)
	colors := make([][]syntax.Token, lines)
	for line := range colors {
		colors[line] = h.Line(nil, line)
	}
	return colors
}

// firstColorDifference is the first line whose tokens differ between got and want, or -1 when
// they are the same.
func firstColorDifference(got, want [][]syntax.Token) int {
	if len(got) != len(want) {
		return min(len(got), len(want))
	}
	for line := range got {
		if !slices.Equal(got[line], want[line]) {
			return line
		}
	}
	return -1
}

// expected is the colors of text from a highlighter made for it alone, which tokenizes it from
// its first line to its last and never gives up on a line.
func (w *colorWatch) expected(text string) [][]syntax.Token {
	if colors, ok := w.fresh[text]; ok {
		return colors
	}
	doc := rope.FromString(text)
	h := syntax.NewHighlighter(w.syn, doc, syntax.HighlighterOptions{LineLimit: -1})
	defer h.Close()
	colors := readColors(h, doc.LineCount())
	w.fresh[text] = colors
	return colors
}

// settle waits until the colors of the view are what a fresh highlighter gives its text, and
// fails with the first line that is not when they never are. It reads the colors again each time
// the view's highlighter says it changed some, and its wait is bounded.
func (w *colorWatch) settle(at string) {
	w.t.Helper()
	text := w.v.contents()
	want := w.expected(text)
	timeout := time.NewTimer(colorTimeout)
	defer timeout.Stop()
	for {
		got := readColors(w.v.hl, len(want))
		line := firstColorDifference(got, want)
		if line < 0 {
			return
		}
		select {
		case <-w.woken:
		case <-timeout.C:
			w.t.Fatalf("%s: line %d, %q, is colored %v, want %v, and %v went by without the highlighter changing it",
				at, line, strings.Split(text, "\n")[line], got[line], want[line], colorTimeout)
		}
	}
}

// Undo and redo keep the color of every line what coloring the whole text gives, across edits
// that open and close comments and strings, move lines, and replace the text. The view's
// highlighter follows each step as it follows an edit, and the lines it kept from before must
// not stay colored for the text they were in.
func TestUndoAndRedoKeepTheColorsOfEveryLine(t *testing.T) {
	w := newColorWatch(t, undoSource())
	v := w.v
	w.settle("when opened")

	offset := func(s string) int {
		t.Helper()
		i := strings.Index(v.contents(), s)
		if i < 0 {
			t.Fatalf("the text has no %q", s)
		}
		return i
	}
	insertBefore := func(s, text string) func(v *View) {
		return func(v *View) {
			at := offset(s)
			v.edit(at, at, text, editOther)
		}
	}
	replace := func(s, text string) func(v *View) {
		return func(v *View) {
			at := offset(s)
			v.edit(at, at+len(s), text, editOther)
		}
	}
	texts := recordEdits(t, v, func() { readColors(v.hl, v.text.LineCount()) },
		// A comment opens in the second function and closes in the sixth, and a raw string opens
		// in the eighth and closes in the tenth: every line between them changes color.
		insertBefore("func add2(", "/* "),
		insertBefore("func add6(", "*/ "),
		replace("\"sum 8\"", "`sum 8"),
		replace("\"sum 10\"", "sum 10`"),
		// Two lines become one.
		replace("// the sum\n\ts := \"sum 1\"", "\"sum 1\""),
		insertBefore("func add11(", "var table = map[string]int{\n\t\"one\": 1,\n\t\"two\": 2, // pair\n}\n\n"),
		// Wide and accented characters move every token after them in their line.
		func(v *View) {
			at := offset("\"sum 12\"") + 1
			v.edit(at, at, "世界 é ", editOther)
		},
		insertBefore("package sample", "// Code generated by hand. DO NOT EDIT.\n\n"),
		func(v *View) {
			n := v.text.Len()
			v.edit(n, n, "\nfunc tail() {\n\tfor i := 0; i < 3; i++ {\n\t}\n}\n", editOther)
		},
		// The whole text is replaced by one that ends inside a comment.
		func(v *View) {
			v.SelectAll()
			v.insert("package other\n\nvar x = 1 /* only\n", editOther)
		},
	)
	w.settle("after the edits")

	walkHistory(t, v, texts, w.settle)

	// Steps that follow one another with no wait between them, so the highlighter is still
	// working on one when the next arrives.
	for v.Undo() {
	}
	if got := v.contents(); got != texts[0] {
		t.Fatalf("undoing every edit left %d bytes, want the %d of the text", len(got), len(texts[0]))
	}
	w.settle("after undoing every edit at once")
	for v.Redo() {
	}
	if got := v.contents(); got != texts[len(texts)-1] {
		t.Fatalf("redoing every edit left %d bytes, want the %d of the last", len(got), len(texts[len(texts)-1]))
	}
	w.settle("after redoing every edit at once")
	for range 4 {
		v.Undo()
	}
	for range 2 {
		v.Redo()
	}
	for range 3 {
		v.Undo()
	}
	if got, want := v.contents(), texts[len(texts)-1-4+2-3]; got != want {
		t.Fatalf("undoing and redoing in bursts left %d bytes, want the %d of that step", len(got), len(want))
	}
	w.settle("after undoing and redoing in bursts")
}

// Undo and redo keep the rows a wrapped view lays out for every line what laying out the whole
// text again gives, and keep the layout current instead of dropping it for the next paint to
// make again.
func TestUndoAndRedoKeepTheRowsOfEveryLine(t *testing.T) {
	v := newTestView(t, strings.Repeat("word ", 30)+"\nshort\n"+strings.Repeat("中文", 40)+"\n\tend\n"+strings.Repeat("tail ", 25))
	_, cols := paintWrapped(t, v, gfx.Rect{Width: 300, Height: 600})
	check := func(at string) {
		t.Helper()
		if len(v.wraps) != v.text.LineCount() {
			t.Fatalf("%s: the layout has %d lines, want the text's %d: it was dropped, not followed", at, len(v.wraps), v.text.LineCount())
		}
		v.ensureRows()
		row := 0
		for line := range v.text.LineCount() {
			if got := v.lineRow(line); got != row {
				t.Fatalf("%s: line %d starts at row %d, want %d", at, line, got, row)
			}
			row += len(wrapLine(nil, v.text.Line(line), cols))
		}
		if got := v.rowCount(); got != row {
			t.Fatalf("%s: rowCount = %d, want %d", at, got, row)
		}
	}
	check("painting")

	texts := recordEdits(t, v, func() { check("an edit") },
		// A wrapped line grows by a row or more.
		func(v *View) { v.edit(10, 10, "long long long ", editOther) },
		// One line becomes several, one of them wrapped.
		func(v *View) { v.insert("\n\nnew "+strings.Repeat("y", 90)+"\n", editOther) },
		// Lines are joined by a deletion across them.
		func(v *View) {
			v.anchor, v.caret = 5, v.text.LineStart(3)+4
			v.insert("", editOther)
		},
		// A line of wide characters shrinks to fewer than a row.
		func(v *View) {
			at := strings.Index(v.contents(), "中文")
			v.edit(at, at+len("中文")*10, "x", editOther)
		},
		func(v *View) {
			n := v.text.Len()
			v.edit(n, n, " more words to wrap around\nand a last line", editOther)
		},
		func(v *View) { v.edit(0, 0, "first\n", editOther) },
		// The whole text becomes one line of a few characters.
		func(v *View) {
			v.SelectAll()
			v.insert("tiny", editOther)
		},
	)
	walkHistory(t, v, texts, check)
}

// Undo and redo keep what the view read of a long line before the change they make and of the
// long lines they did not touch, and every column of a long line is still the one counting the
// whole line gives afterwards. A change that moves the lines after it drops the stops of those.
func TestUndoAndRedoKeepTheStopsOfLongLines(t *testing.T) {
	line := longText(5 * longLine / 2)
	v := newTestView(t, line+"\nshort\n"+line)
	mid := strings.Index(line[len(line)/2:], "中") + len(line)/2
	check := func(at string) {
		t.Helper()
		long := 0
		for n := range v.text.LineCount() {
			l := v.ref(n)
			if !l.long {
				continue
			}
			long++
			whole := v.text.Line(n)
			want := wholeCells(t, whole)
			for _, col := range boundaries(whole, 997) {
				if got := v.cellsAt(l, col); got != want[col] {
					t.Fatalf("%s: line %d cellsAt(%d) = %d, want %d", at, n, col, got, want[col])
				}
			}
		}
		if long < 2 {
			t.Fatalf("%s: the text has %d long lines, want two or more", at, long)
		}
	}
	// kept says line 0 kept the stops before the change at byte from and none at or after it.
	kept := func(at string, from int) {
		t.Helper()
		if v.stopsRevision != v.revision {
			t.Fatalf("%s: the stops are those of revision %d, not the text's %d, so all were dropped", at, v.stopsRevision, v.revision)
		}
		s := v.stops[0]
		if s == nil || s.done || len(s.stops) < 2 {
			t.Fatalf("%s: line 0 kept no stops before the change at byte %d", at, from)
		}
		last := s.stops[len(s.stops)-1].at
		if last+utf8.UTFMax > from {
			t.Fatalf("%s: line 0 kept a stop at byte %d, within a character of the change at %d or after it", at, last, from)
		}
		if last < from-stopBytes-16 {
			t.Fatalf("%s: line 0 kept stops only up to byte %d, dropping some well before the change at %d", at, last, from)
		}
	}
	// intact says the lines the change did not move kept all their stops.
	intact := func(at string, lines ...int) {
		t.Helper()
		if v.stopsRevision != v.revision {
			t.Fatalf("%s: the stops are those of revision %d, not the text's %d, so all were dropped", at, v.stopsRevision, v.revision)
		}
		for _, n := range lines {
			if s := v.stops[n]; s == nil || !s.done {
				t.Fatalf("%s: line %d lost its stops, though the change did not touch or move it", at, n)
			}
		}
	}

	check("before any edit")
	texts := recordEdits(t, v, func() { check("an edit") },
		func(v *View) { v.edit(mid, mid, "\t中x", editOther) },
		// The first byte of a character goes, leaving the rest of it with no start.
		func(v *View) { v.edit(mid+1, mid+2, "", editOther) },
		func(v *View) {
			at := v.text.LineStart(1)
			v.edit(at, at+1, "S", editOther)
		},
		// The long line breaks in two, which moves the lines after it.
		func(v *View) { v.edit(mid-7, mid-7, "\n", editOther) },
	)
	step := func(at string, move func() bool, want int) {
		t.Helper()
		if !move() {
			t.Fatalf("%s: there was no step to take", at)
		}
		if got := v.contents(); got != texts[want] {
			t.Fatalf("%s: the text is %d bytes, want the %d of step %d", at, len(got), len(texts[want]), want)
		}
	}

	step("undoing edit 4", v.Undo, 3)
	kept("undoing edit 4", mid-7)
	if len(v.stops) != 1 {
		t.Fatalf("undoing edit 4 joined two lines, which renumbered the ones after them, yet %d lines kept stops, want line 0 only", len(v.stops))
	}
	check("undoing edit 4")

	step("undoing edit 3", v.Undo, 2)
	intact("undoing edit 3", 0, 2)
	check("undoing edit 3")

	step("undoing edit 2", v.Undo, 1)
	kept("undoing edit 2", mid+1)
	intact("undoing edit 2", 2)
	check("undoing edit 2")

	step("undoing edit 1", v.Undo, 0)
	kept("undoing edit 1", mid)
	intact("undoing edit 1", 2)
	check("undoing edit 1")

	step("redoing edit 1", v.Redo, 1)
	kept("redoing edit 1", mid)
	intact("redoing edit 1", 2)
	check("redoing edit 1")

	step("redoing edit 2", v.Redo, 2)
	kept("redoing edit 2", mid+1)
	intact("redoing edit 2", 2)
	check("redoing edit 2")

	step("redoing edit 3", v.Redo, 3)
	intact("redoing edit 3", 0, 2)
	check("redoing edit 3")

	step("redoing edit 4", v.Redo, 4)
	kept("redoing edit 4", mid-7)
	if len(v.stops) != 1 {
		t.Fatalf("redoing edit 4 split a line, which renumbered the ones after it, yet %d lines kept stops, want line 0 only", len(v.stops))
	}
	check("redoing edit 4")
}
