package editorview

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// newTestView is a view of text with no grammar, its caret at the start.
func newTestView(t *testing.T, text string) *View {
	t.Helper()
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte(text))})
	t.Cleanup(v.Close)
	return v
}

func (v *View) typeText(text string) {
	for _, r := range text {
		v.applyText(app.TextEvent{Kind: app.TextInsert, Text: string(r)})
	}
}

func (v *View) press(key gfx.Key, modifiers gfx.Modifiers) {
	v.Key(gfx.KeyEvent{Key: key, Modifiers: modifiers, Target: v.cfg.HitID})
}

func (v *View) contents() string {
	_, text := v.Text()
	return text.String()
}

func TestTypingIsOneUndoStepPerWord(t *testing.T) {
	v := newTestView(t, "")
	v.typeText("hello world")
	if got := v.contents(); got != "hello world" {
		t.Fatalf("text = %q", got)
	}
	if !v.Dirty() {
		t.Fatal("an edited view is not dirty")
	}
	v.Undo()
	if got := v.contents(); got != "hello" {
		t.Fatalf("after one undo = %q, want the word before the space kept", got)
	}
	v.Undo()
	if got := v.contents(); got != "" || v.Dirty() {
		t.Fatalf("after two undos = %q dirty=%v, want the saved empty text", got, v.Dirty())
	}
	v.Redo()
	v.Redo()
	if got := v.contents(); got != "hello world" {
		t.Fatalf("after two redos = %q", got)
	}
}

func TestBackspacesAreOneUndoStep(t *testing.T) {
	v := newTestView(t, "abcdef")
	v.press(gfx.KeyEnd, 0)
	for range 3 {
		v.press(gfx.KeyBackspace, 0)
	}
	if got := v.contents(); got != "abc" {
		t.Fatalf("text = %q", got)
	}
	v.Undo()
	if got := v.contents(); got != "abcdef" {
		t.Fatalf("after undo = %q, want every deleted character back at once", got)
	}
}

func TestEnterBetweenBracesIndentsAndClosesOnItsOwnLine(t *testing.T) {
	v := newTestView(t, "    func() {}")
	v.press(gfx.KeyEnd, 0)
	v.press(gfx.KeyLeft, 0)
	v.press(gfx.KeyEnter, 0)
	want := "    func() {\n        \n    }"
	if got := v.contents(); got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
	if line, col := v.Caret(); line != 1 || col != 8 {
		t.Fatalf("caret = %d:%d, want 1:8", line, col)
	}
}

func TestWordMovesAndSelection(t *testing.T) {
	v := newTestView(t, "alpha beta.gamma")
	v.press(gfx.KeyRight, gfx.ModifierAlt)
	if _, col := v.Caret(); col != 5 {
		t.Fatalf("after a word right caret col = %d, want 5", col)
	}
	v.press(gfx.KeyRight, gfx.ModifierAlt|gfx.ModifierShift)
	if got := v.SelectedText(); got != " beta" {
		t.Fatalf("selected %q, want %q", got, " beta")
	}
	v.typeText("X")
	if got := v.contents(); got != "alphaX.gamma" {
		t.Fatalf("text = %q", got)
	}
}

func TestTabIndentsAndOutdentsSelectedLines(t *testing.T) {
	v := newTestView(t, "a\nb\n")
	v.SelectAll()
	v.press(gfx.KeyTab, 0)
	if got := v.contents(); got != "    a\n    b\n" {
		t.Fatalf("after Tab = %q", got)
	}
	v.press(gfx.KeyTab, gfx.ModifierShift)
	if got := v.contents(); got != "a\nb\n" {
		t.Fatalf("after Shift-Tab = %q", got)
	}
	if v.Dirty() {
		t.Fatal("a view edited back to its saved text is dirty")
	}
}

func TestMarkSavedClearsDirty(t *testing.T) {
	v := newTestView(t, "x")
	v.typeText("y")
	_, text := v.Text()
	v.MarkSaved(text)
	if v.Dirty() {
		t.Fatal("a saved view is dirty")
	}
	v.Undo()
	if !v.Dirty() {
		t.Fatal("undoing past the save does not make the view dirty")
	}
}

// TestRevisionCountsEveryChange checks that edits, undo and redo each move the revision a
// failed save is logged with, and that saving does not.
func TestRevisionCountsEveryChange(t *testing.T) {
	v := newTestView(t, "x")
	if v.Revision() != 0 {
		t.Fatalf("a view just read is at revision %d", v.Revision())
	}
	v.typeText("y")
	typed := v.Revision()
	if typed == 0 {
		t.Fatal("typing did not change the revision")
	}
	_, text := v.Text()
	v.MarkSaved(text)
	if v.Revision() != typed {
		t.Fatalf("saving moved the revision from %d to %d", typed, v.Revision())
	}
	v.Undo()
	if v.Revision() != typed+1 {
		t.Fatalf("after undo the revision is %d, want %d", v.Revision(), typed+1)
	}
	v.Redo()
	if v.Revision() != typed+2 {
		t.Fatalf("after redo the revision is %d, want %d", v.Revision(), typed+2)
	}
}

func TestCellsCountTabsAndWideCharacters(t *testing.T) {
	cases := []struct {
		line string
		col  int
		want int
	}{
		{"\tx", 1, tabSize},
		{"ab\tx", 3, tabSize},
		{"中文x", len("中文"), 4},
		{"abc", 2, 2},
	}
	for _, c := range cases {
		if got := cellsOf(c.line, c.col); got != c.want {
			t.Errorf("cellsOf(%q, %d) = %d, want %d", c.line, c.col, got, c.want)
		}
	}
	if got := columnAt("中文x", 2.6); got != len("中") {
		t.Errorf("columnAt in a wide character = %d, want its nearer edge %d", got, len("中"))
	}
}

func TestReloadKeepsRecoverableOldTextAndRefusesDirtyEdits(t *testing.T) {
	v := newTestView(t, "first")
	if !v.Reload(Prepare([]byte("second"))) {
		t.Fatal("clean document did not reload")
	}
	if got := v.contents(); got != "second" || v.Dirty() {
		t.Fatalf("reloaded %q dirty=%v", got, v.Dirty())
	}
	if !v.Undo() || v.contents() != "first" || !v.Dirty() {
		t.Fatal("reload discarded the previous text")
	}
	if v.Reload(Prepare([]byte("third"))) {
		t.Fatal("reload replaced dirty input")
	}
	if v.contents() != "first" {
		t.Fatal("dirty input was changed")
	}
}

func TestGoToLineClampsAndPreservesComposition(t *testing.T) {
	v := newTestView(t, "first\nsecond\nthird")
	if !v.GoToLine(2) {
		t.Fatal("line navigation was refused")
	}
	if line, column := v.Caret(); line != 1 || column != 0 {
		t.Fatalf("caret = %d:%d", line, column)
	}
	if !v.GoToLine(999) {
		t.Fatal("out-of-range line was refused")
	}
	if line, _ := v.Caret(); line != 2 {
		t.Fatalf("line was not clamped: %d", line)
	}
	v.preedit.Composing = true
	if v.GoToLine(1) {
		t.Fatal("navigation replaced active input method composition")
	}
	if line, _ := v.Caret(); line != 2 {
		t.Fatal("composition caret changed")
	}
}

func TestGoToNavigationUTF16AndWholeLine(t *testing.T) {
	v := newTestView(t, "first\nA😀中Z\nlast")
	for _, tc := range []struct {
		line, column      int
		whole             bool
		start, end, utf16 int
	}{
		{1, 0, true, 6, 15, 5},
		{1, 1, false, 7, 7, 1},
		{1, 2, false, 7, 7, 1}, // A half surrogate never splits the UTF-8 rune.
		{1, 3, false, 11, 11, 3},
		{1, 999, false, 15, 15, 5},
		{999, 999, false, 20, 20, 4},
	} {
		if !v.GoToNavigation(tc.line, tc.column, tc.whole) {
			t.Fatal("navigation refused")
		}
		start, end := v.Selection()
		_, col := v.CaretUTF16()
		if start != tc.start || end != tc.end || col != tc.utf16 {
			t.Errorf("%+v: selection = %d:%d, column = %d", tc, start, end, col)
		}
	}
	v.preedit.Composing = true
	if v.GoToNavigation(0, 0, true) {
		t.Fatal("navigation interrupted composition")
	}
}

func TestCaretUTF16TracksEditsAndUndo(t *testing.T) {
	v := newTestView(t, "A😀中Z")
	v.GoToNavigation(0, 3, false)
	if _, col := v.CaretUTF16(); col != 3 {
		t.Fatalf("initial column %d", col)
	}
	v.typeText("🚀")
	if _, col := v.CaretUTF16(); col != 5 {
		t.Fatalf("after insertion column %d", col)
	}
	v.press(gfx.KeyBackspace, 0)
	if _, col := v.CaretUTF16(); col != 3 {
		t.Fatalf("after deletion column %d", col)
	}
	v.Undo()
	if _, col := v.CaretUTF16(); col != 5 {
		t.Fatalf("after undo column %d", col)
	}
	v.typeText("\n")
	if line, col := v.CaretUTF16(); line != 1 || col != 0 {
		t.Fatalf("after newline %d:%d", line, col)
	}
}

func TestEditCallbackReportsLSPRange(t *testing.T) {
	var edits []Edit
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte("abc\ndef")), OnEdit: func(edit Edit) { edits = append(edits, edit) }})
	t.Cleanup(v.Close)
	if !v.GoToNavigation(1, 1, false) {
		t.Fatal("navigation refused")
	}
	v.typeText("X")
	if len(edits) != 1 {
		t.Fatalf("edits = %+v", edits)
	}
	if got := edits[0]; got.StartLine != 1 || got.StartColumn != 1 || got.EndLine != 1 || got.EndColumn != 1 || got.Text != "X" {
		t.Fatalf("range edit = %+v", got)
	}
	// Undo and redo report the bytes the step changes, as the keystroke they take back or do
	// again, not a replacement of the whole document.
	v.Undo()
	if len(edits) != 2 {
		t.Fatalf("edits after undo = %+v", edits)
	}
	if got := edits[1]; got != (Edit{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 2}) {
		t.Fatalf("undo edit = %+v", got)
	}
	v.Redo()
	if len(edits) != 3 {
		t.Fatalf("edits after redo = %+v", edits)
	}
	if got := edits[2]; got != (Edit{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 1, Text: "X"}) {
		t.Fatalf("redo edit = %+v", got)
	}
	if text, _ := v.Text(); string(text) != "abc\ndXef" {
		t.Fatalf("text after redo = %q", text)
	}
}

// The column of an offset is the same whether positionAt counts it from the start of its line or
// from the caret's column that CaretUTF16 keeps, before or after the caret, on a line of characters
// of one, two and three bytes and of one that takes two UTF-16 units.
func TestPositionAtCountsFromTheNearerKnownColumn(t *testing.T) {
	line := strings.Repeat("a\u00e9\u4e2d\U0001F600", 40)
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte("first\n" + line + "\nlast"))})
	t.Cleanup(v.Close)
	lineStart, lineEnd := v.text.LineStart(1), v.text.LineStart(1)+len(line)
	want := func(offset int) int { return utf16Length(line[:offset-lineStart]) }
	boundary := func(offset int) bool { return offset == lineEnd || utf8.RuneStart(v.text.ByteAt(offset)) }
	for caret := lineStart; caret <= lineEnd; caret++ {
		if !boundary(caret) {
			continue
		}
		v.anchor, v.caret = caret, caret
		if _, column := v.CaretUTF16(); column != want(caret) {
			t.Fatalf("caret at %d: CaretUTF16 column %d, want %d", caret, column, want(caret))
		}
		for offset := lineStart; offset <= lineEnd; offset++ {
			if !boundary(offset) {
				continue
			}
			if gotLine, column := v.positionAt(offset); gotLine != 1 || column != want(offset) {
				t.Fatalf("caret at %d: positionAt(%d) = %d:%d, want 1:%d", caret, offset, gotLine, column, want(offset))
			}
		}
	}
	// An offset on another line than the caret's is counted from its own line's start.
	if gotLine, column := v.positionAt(v.text.LineStart(2) + 2); gotLine != 2 || column != 2 {
		t.Fatalf("positionAt on the last line = %d:%d, want 2:2", gotLine, column)
	}
}
