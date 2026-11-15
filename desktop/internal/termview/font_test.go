package termview

import (
	"math"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// The tests paint into an area of 548 by 496 points on a canvas whose cell is half the font
// size wide and three points taller than it: 6.5 by 16 at the default size. The margins leave
// 80 columns and 30 rows, and every position below is a whole or a half number, so they are
// exact in float32.
var fontTestArea = gfx.Rect{Width: 548, Height: 496}

// fontTestLook has a different color for each thing a test looks for in a paint.
var fontTestLook = Look{
	Dark:       true,
	Background: gfx.RGB(0, 0, 0),
	Foreground: gfx.RGB(255, 255, 255),
	Cursor:     gfx.RGB(255, 0, 0),
	Selection:  gfx.RGB(0, 0, 255),
}

// resizeShell is a fake shell that keeps the sizes the view handed the pty.
type resizeShell struct {
	fakeShell
	sizes [][2]int
}

func (s *resizeShell) Resize(cols, rows int) { s.sizes = append(s.sizes, [2]int{cols, rows}) }

// fontRig is a view painted on a canvas with the measured cell above, its shell standing by.
// The view is not focused, so its cursor is an outline of its cell and the text of its row
// stays whole.
type fontRig struct {
	view   *View
	shell  *resizeShell
	canvas *gfx.Canvas
}

// newFontRig paints a view of the default font once, which lays out 80 by 30 cells and starts
// the shell at that size, so no resize has reached it yet.
func newFontRig(t *testing.T) *fontRig {
	t.Helper()
	fake := &resizeShell{}
	view := New(Config{
		HitID: gfx.Item(1),
		Shell: "tool",
		Args:  []string{},
		start: func(localshell.Config) (shell, error) { return fake, nil },
	})
	t.Cleanup(func() { view.Close() })
	canvas := new(gfx.Canvas)
	canvas.SetCellMeasurer(func(size float32, _ gfx.MonoFace) (float32, float32) { return size / 2, size + 3 })
	rig := &fontRig{view: view, shell: fake, canvas: canvas}
	rig.paint()
	return rig
}

// paint draws the view into a canvas emptied of the last paint.
func (r *fontRig) paint() {
	r.canvas.Reset()
	r.view.Paint(r.canvas, fontTestArea, fontTestLook)
}

// print writes text into the screen as the program's output.
func (r *fontRig) print(text string) { r.view.screen.Write([]byte(text)) }

// labelOf is the label the last paint drew for value.
func labelOf(t *testing.T, canvas *gfx.Canvas, value string) gfx.Text {
	t.Helper()
	for _, text := range canvas.Texts() {
		if text.Value == value {
			return text
		}
	}
	t.Fatalf("the paint drew no label of %q", value)
	return gfx.Text{}
}

// rectangleWhere is the first rectangle of the last paint that match accepts; what names it
// for the failure.
func rectangleWhere(t *testing.T, canvas *gfx.Canvas, what string, match func(gfx.Rectangle) bool) gfx.Rectangle {
	t.Helper()
	for _, rectangle := range canvas.Rectangles() {
		if match(rectangle) {
			return rectangle
		}
	}
	t.Fatalf("the paint drew no %s", what)
	return gfx.Rectangle{}
}

// ligatureFlags is the Ligatures flag of each run of the label drawn for value.
func ligatureFlags(t *testing.T, canvas *gfx.Canvas, value string) []bool {
	t.Helper()
	runs := canvas.TextRuns(labelOf(t, canvas, value))
	if len(runs) == 0 {
		t.Fatalf("the label of %q has no runs", value)
	}
	flags := make([]bool, len(runs))
	for index, run := range runs {
		flags[index] = run.Ligatures
	}
	return flags
}

// A new view draws with the font it drew with before the font could be chosen.
func TestDefaultFontIsWhatTheTerminalAlwaysDrewWith(t *testing.T) {
	want := Font{Face: gfx.MonoSystem, Size: 13, LineSpacing: 1, Ligatures: true}
	if got := DefaultFont(); got != want {
		t.Fatalf("DefaultFont() = %+v, want %+v", got, want)
	}
	if got := New(Config{}).font; got != want {
		t.Fatalf("a new view's font = %+v, want %+v", got, want)
	}
}

// A size or spacing that names nothing usable falls back to its default, so the font a view
// holds is always one that can be laid out and two fonts that draw alike are equal.
func TestSetFontDefaultsWhatItIsNotGiven(t *testing.T) {
	nan := float32(math.NaN())
	inf := float32(math.Inf(1))
	for _, tc := range []struct {
		name  string
		given Font
		want  Font
	}{
		{
			name:  "nothing given",
			given: Font{},
			want:  Font{Face: gfx.MonoSystem, Size: 13, LineSpacing: 1},
		},
		{
			name:  "negative",
			given: Font{Size: -5, LineSpacing: -1, Ligatures: true},
			want:  Font{Size: 13, LineSpacing: 1, Ligatures: true},
		},
		{
			name:  "not a number or infinite",
			given: Font{Size: nan, LineSpacing: inf},
			want:  Font{Size: 13, LineSpacing: 1},
		},
		{
			name:  "all given",
			given: Font{Face: gfx.MonoClassic, Size: 15, LineSpacing: 1.4, Ligatures: true},
			want:  Font{Face: gfx.MonoClassic, Size: 15, LineSpacing: 1.4, Ligatures: true},
		},
	} {
		view := New(Config{})
		view.SetFont(tc.given)
		if view.font != tc.want {
			t.Errorf("%s: SetFont(%+v) left %+v, want %+v", tc.name, tc.given, view.font, tc.want)
		}
	}
}

// The workbench sets the font on every frame, so a font that draws as the one in use changes
// nothing: no allocation, no new grid, no row prepared again.
func TestSetFontWithTheFontInUseChangesNothing(t *testing.T) {
	rig := newFontRig(t)
	view := rig.view
	rig.print("a->b")
	rig.paint()
	font, layout := view.font, view.layout
	cellW, glyphH, rowH := view.cellW, view.glyphH, view.rowH
	builds, resizes := view.cache.builds, len(rig.shell.sizes)

	// The default font as it is and with its unset fields left unset.
	for _, same := range []Font{
		DefaultFont(),
		{Ligatures: true},
		{Face: gfx.MonoSystem, Size: 13, LineSpacing: 1, Ligatures: true},
	} {
		view.SetFont(same)
		rig.paint()
		if view.font != font || view.layout != layout {
			t.Fatalf("SetFont(%+v): font %+v and layout %+v, want %+v and %+v", same, view.font, view.layout, font, layout)
		}
		if view.cellW != cellW || view.glyphH != glyphH || view.rowH != rowH {
			t.Fatalf("SetFont(%+v): cell %v by %v and row %v, want %v by %v and %v", same, view.cellW, view.glyphH, view.rowH, cellW, glyphH, rowH)
		}
		if view.cache.builds != builds {
			t.Fatalf("SetFont(%+v) made %d rows be prepared again", same, view.cache.builds-builds)
		}
		if len(rig.shell.sizes) != resizes {
			t.Fatalf("SetFont(%+v) resized the shell to %v", same, rig.shell.sizes[resizes:])
		}
	}
	if allocations := testing.AllocsPerRun(100, func() { view.SetFont(DefaultFont()) }); allocations != 0 {
		t.Fatalf("setting the font in use allocates %v times", allocations)
	}
}

// A row is the cell's height times the spacing, rounded to a whole pixel and never under one,
// and a cell with no height has no row. At spacing 1 it is the cell's own height, so a terminal
// that sets no spacing keeps its rows.
func TestRowHeightIsTheCellTimesTheSpacingRoundedToAWholePixel(t *testing.T) {
	for _, tc := range []struct {
		cell, spacing, want float32
	}{
		{16, 1, 16},
		{16, 1.5, 24},
		{15, 1.5, 23},
		{17, 1.25, 21},
		{16, 0.01, 1},
		{0, 1.5, 0},
		{-4, 1, 0},
	} {
		if got := (Font{LineSpacing: tc.spacing}).rowHeight(tc.cell); got != tc.want {
			t.Errorf("a cell %v tall at spacing %v: row %v, want %v", tc.cell, tc.spacing, got, tc.want)
		}
	}
	for cell := float32(1); cell <= 64; cell++ {
		if got := DefaultFont().rowHeight(cell); got != cell {
			t.Fatalf("a cell %v tall at spacing 1: row %v, want the cell's own height", cell, got)
		}
	}
}

// Rows are as tall as the cell times the spacing, and tile the grid at that pitch: a row's
// background and the cursor fill all of it, while the text is the cell's height, centered in
// it. At spacing 1, set or not, nothing moves from where it was drawn before spacing existed.
func TestRowsAreAsTallAsTheSpacingAndTheTextIsCenteredInThem(t *testing.T) {
	for _, tc := range []struct {
		name    string
		spacing float32
		rowH    float32
		inset   float32
		rows    int
	}{
		{name: "unset", spacing: 0, rowH: 16, inset: 0, rows: 30},
		{name: "one", spacing: 1, rowH: 16, inset: 0, rows: 30},
		{name: "one and a half", spacing: 1.5, rowH: 24, inset: 4, rows: 20},
		{name: "two", spacing: 2, rowH: 32, inset: 8, rows: 15},
	} {
		rig := newFontRig(t)
		view := rig.view
		// A line of blue background on the fourth row, with the cursor behind it.
		rig.print("\r\n\r\n\r\n\x1b[44mxyz")
		view.SetFont(Font{LineSpacing: tc.spacing, Ligatures: true})
		rig.paint()

		if _, cell := rig.canvas.MonoCellSize(13, gfx.MonoSystem); view.glyphH != cell || cell != 16 {
			t.Fatalf("%s: the glyph cell is %v tall, the canvas measures %v, want 16", tc.name, view.glyphH, cell)
		}
		if view.rowH != tc.rowH || view.glyphInset() != tc.inset {
			t.Fatalf("%s: row %v and inset %v, want %v and %v", tc.name, view.rowH, view.glyphInset(), tc.rowH, tc.inset)
		}
		if cols, rows := view.screen.Size(); cols != 80 || rows != tc.rows || view.layout.cols != cols || view.layout.rows != rows {
			t.Fatalf("%s: the grid is %d by %d (laid out %d by %d), want 80 by %d", tc.name, cols, rows, view.layout.cols, view.layout.rows, tc.rows)
		}

		top := 8 + 3*tc.rowH // the first row starts after the top margin
		label := labelOf(t, rig.canvas, "xyz")
		if label.Bounds.Y != top+tc.inset || label.Bounds.Height != 16 {
			t.Errorf("%s: the text is at y %v, %v tall, want y %v, 16 tall", tc.name, label.Bounds.Y, label.Bounds.Height, top+tc.inset)
		}
		fill := rectangleWhere(t, rig.canvas, "background of the row's text", func(r gfx.Rectangle) bool {
			return r.Bounds.X == 14 && r.Bounds.Width == 19.5
		})
		if fill.Bounds.Y != top || fill.Bounds.Height != tc.rowH {
			t.Errorf("%s: the background is at y %v, %v tall, want y %v, %v tall", tc.name, fill.Bounds.Y, fill.Bounds.Height, top, tc.rowH)
		}
		// The cursor of a view without the keyboard outlines its cell: the whole of the row's
		// height at the sides, and its last pixel row at the bottom.
		rectangleWhere(t, rig.canvas, "left edge of the cursor, as tall as the row", func(r gfx.Rectangle) bool {
			return r.Color == fontTestLook.Cursor && r.Bounds.X == 33.5 && r.Bounds.Y == top && r.Bounds.Width == 1 && r.Bounds.Height == tc.rowH
		})
		rectangleWhere(t, rig.canvas, "bottom edge of the cursor, on the last pixel row of the row", func(r gfx.Rectangle) bool {
			return r.Color == fontTestLook.Cursor && r.Bounds.X == 33.5 && r.Bounds.Y == top+tc.rowH-1 && r.Bounds.Width == 6.5 && r.Bounds.Height == 1
		})
	}
}

// A new font changes the grid, and the change reaches the screen and the shell at the next
// paint, through the resize any change of the area goes through, and not before: setting the
// font only chooses it.
func TestChangingTheFontResizesTheScreenAndTheShellAtTheNextPaint(t *testing.T) {
	rig := newFontRig(t)
	view := rig.view
	if cols, rows := view.screen.Size(); cols != 80 || rows != 30 || len(rig.shell.sizes) != 0 {
		t.Fatalf("before any change the grid is %d by %d with %d resizes, want 80 by 30 with none", cols, rows, len(rig.shell.sizes))
	}

	// The same cell at one and a half times the row: the area holds a third fewer rows.
	view.SetFont(Font{LineSpacing: 1.5, Ligatures: true})
	if cols, rows := view.screen.Size(); cols != 80 || rows != 30 || len(rig.shell.sizes) != 0 {
		t.Fatalf("SetFont resized to %d by %d with %d resizes, want nothing before the paint", cols, rows, len(rig.shell.sizes))
	}
	rig.paint()
	if cols, rows := view.screen.Size(); cols != 80 || rows != 20 {
		t.Fatalf("spacing 1.5: the screen is %d by %d, want 80 by 20", cols, rows)
	}

	// A larger font: the cell is 10 by 23, so there are fewer columns and rows.
	view.SetFont(Font{Size: 20, LineSpacing: 1, Ligatures: true})
	rig.paint()
	if cols, rows := view.screen.Size(); cols != 52 || rows != 20 {
		t.Fatalf("size 20: the screen is %d by %d, want 52 by 20", cols, rows)
	}

	// Back to the default, which returns the original grid.
	view.SetFont(DefaultFont())
	rig.paint()
	if cols, rows := view.screen.Size(); cols != 80 || rows != 30 {
		t.Fatalf("default: the screen is %d by %d, want 80 by 30", cols, rows)
	}
	if want := [][2]int{{80, 20}, {52, 20}, {80, 30}}; !slices.Equal(rig.shell.sizes, want) {
		t.Fatalf("the shell was resized to %v, want %v", rig.shell.sizes, want)
	}
}

// The pointer finds the cell under it by the row pitch, not by the cell's height, so a click
// and a selection land on the row they are drawn on.
func TestPointerAndSelectionFollowTheRowPitch(t *testing.T) {
	rig := newFontRig(t)
	view := rig.view
	rig.print("\r\n\r\n\r\nxyz")
	view.SetFont(Font{LineSpacing: 1.5, Ligatures: true})
	rig.paint()

	// The rows start at y 8 and are 24 tall: the fourth is from 80 to 104.
	for _, tc := range []struct {
		y   float32
		row int
	}{{8, 0}, {31.9, 0}, {32, 1}, {79.9, 2}, {80, 3}, {103.9, 3}, {104, 4}} {
		if got := view.positionAt(14, tc.y).Row; got != tc.row {
			t.Errorf("a pointer at y %v is on row %d, want %d", tc.y, got, tc.row)
		}
	}
	// The columns start at x 14 and are 6.5 wide, which the font's spacing does not change.
	for _, tc := range []struct {
		x      float32
		column int
	}{{14, 0}, {20.4, 0}, {20.5, 1}, {33.5, 3}} {
		if got := view.positionAt(tc.x, 80).Column; got != tc.column {
			t.Errorf("a pointer at x %v is on column %d, want %d", tc.x, got, tc.column)
		}
	}

	// A double click on the text takes the word, and its highlight is the row's whole height.
	result, handled := view.Pointer(gfx.PointerEvent{
		Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 2,
		X: 16, Y: 82, Target: gfx.Item(1),
	})
	if !handled || !result.Handled {
		t.Fatalf("the double click was not handled: %+v, %v", result, handled)
	}
	rig.paint()
	highlight := rectangleWhere(t, rig.canvas, "selection", func(r gfx.Rectangle) bool {
		return r.Color == fontTestLook.Selection
	})
	if highlight.Bounds.X != 14 || highlight.Bounds.Y != 80 || highlight.Bounds.Height != 24 {
		t.Fatalf("the selection is %+v, want it from x 14 on the whole of the fourth row, y 80 and 24 tall", highlight.Bounds)
	}
}

// The input method composes in the glyph cell of the cursor's row, so it lines up with the
// text drawn there at any spacing, and it is told the font in use.
func TestInputMethodBoundsAreTheGlyphCellInTheCursorRow(t *testing.T) {
	for _, tc := range []struct {
		spacing float32
		y       float32
	}{{1, 56}, {1.5, 84}, {2, 112}} {
		rig := newFontRig(t)
		view := rig.view
		rig.print("\r\n\r\n\r\nxyz")
		font := Font{Face: gfx.MonoClassic, Size: 13, LineSpacing: tc.spacing, Ligatures: true}
		view.SetFont(font)
		rig.paint()

		input := view.TextInput(app.TextInputContext{ID: gfx.Item(1)})
		if input == nil {
			t.Fatalf("spacing %v: no text input for the terminal's hit", tc.spacing)
		}
		want := gfx.Rect{X: 33.5, Y: tc.y, Width: 6.5, Height: 16}
		if input.Bounds != want {
			t.Errorf("spacing %v: the input is at %+v, want %+v", tc.spacing, input.Bounds, want)
		}
		if input.FontSize != font.Size || input.MonoFace != font.Face {
			t.Errorf("spacing %v: the input is in size %v, face %v, want %v, %v", tc.spacing, input.FontSize, input.MonoFace, font.Size, font.Face)
		}
	}
}

// The wheel moves a row for each row pitch of travel and the scrollbar's content is the
// history times the pitch, so a terminal with line spacing scrolls as far as it looks.
func TestWheelAndScrollbarCountRowsAtTheRowPitch(t *testing.T) {
	rig := newFontRig(t)
	view := rig.view
	rig.print(strings.Repeat("line\r\n", 60))
	view.SetFont(Font{LineSpacing: 1.5, Ligatures: true})
	rig.paint()
	if view.screen.Scrollback() < 10 {
		t.Fatalf("the screen kept %d lines of history, want enough to scroll in", view.screen.Scrollback())
	}

	// 72 points are three rows of 24; at the cell's 16 they would be four and a half. A
	// negative delta reveals older lines.
	result, handled := view.Scroll(gfx.ScrollEvent{Target: gfx.Item(1), DeltaY: -72, Precise: true})
	if !handled || !result.Handled {
		t.Fatalf("the wheel was not handled: %+v, %v", result, handled)
	}
	if offset := view.screen.ViewOffset(); offset != 3 {
		t.Fatalf("72 points of wheel moved the view %d lines, want 3", offset)
	}

	history := float32(view.screen.Scrollback())
	bar := view.scrollArea(nil, view.layout.area, 1).Geometry()
	if want := history * 24; bar.MaxOffsetY != want {
		t.Errorf("the scrollbar's content reaches %v past the grid, want the history of %v lines at 24 each", bar.MaxOffsetY, history)
	}
	if want := (history - 3) * 24; bar.OffsetY != want {
		t.Errorf("the scrollbar is at %v, want %v: the view is three lines back", bar.OffsetY, want)
	}
}

// Ligatures are asked for only when the font has them on, and only for the runs that could
// take them: plain ASCII of two cells or more. Rows already prepared are prepared again when
// the setting changes, though no line did, and only then.
func TestLigaturesFollowTheFont(t *testing.T) {
	rig := newFontRig(t)
	view := rig.view
	rig.print("a->b\r\nx\r\n中文")
	// A run of ASCII with room for a ligature joins; a lone cell and wide characters never do.
	rows := []struct {
		text   string
		joined bool
	}{
		{"a->b", true},
		{"x", false},
		{"中文", false},
	}
	check := func(step string, ligatures bool) {
		t.Helper()
		for _, row := range rows {
			for _, flag := range ligatureFlags(t, rig.canvas, row.text) {
				if want := ligatures && row.joined; flag != want {
					t.Errorf("%s: a run of %q has Ligatures %v, want %v", step, row.text, flag, want)
				}
			}
		}
	}

	rig.paint()
	check("default font", true)
	builds := view.cache.builds

	// Off: every row is prepared again, and since the grid is as it was the shell hears nothing.
	view.SetFont(Font{Ligatures: false})
	rig.paint()
	check("ligatures off", false)
	if got, want := view.cache.builds-builds, uint64(view.layout.rows); got != want {
		t.Errorf("turning ligatures off prepared %d rows again, want all %d", got, want)
	}
	if len(rig.shell.sizes) != 0 {
		t.Errorf("turning ligatures off resized the shell to %v", rig.shell.sizes)
	}

	// Painting on with the font unchanged reuses the rows.
	builds = view.cache.builds
	rig.paint()
	check("ligatures still off", false)
	if view.cache.builds != builds {
		t.Errorf("a paint with nothing changed prepared %d rows", view.cache.builds-builds)
	}

	// On again: every row is prepared again.
	view.SetFont(DefaultFont())
	rig.paint()
	check("ligatures on again", true)
	if got, want := view.cache.builds-builds, uint64(view.layout.rows); got != want {
		t.Errorf("turning ligatures on prepared %d rows again, want all %d", got, want)
	}
}
