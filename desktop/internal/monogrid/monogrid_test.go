package monogrid

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

type span struct{ column, bytes, cells int32 }

func spans(runs []ui.TextRun) []span {
	out := make([]span, len(runs))
	for i, run := range runs {
		out[i] = span{run.Column, run.Bytes, run.Cells}
	}
	return out
}

// testCanvas is a canvas whose labels are as wide as a font with an em-wide CJK character
// draws them: a cell is 0.6 em, so three wide characters take five cells, not six.
func testCanvas() *ui.Canvas {
	canvas := new(ui.Canvas)
	canvas.SetMeasurer(func(value string, size, _ float32) float32 {
		width := float32(0)
		for _, r := range value {
			switch text.CellWidth(r) {
			case 2:
				width += size
			case 1:
				width += 0.6 * size
			}
		}
		return width
	})
	return canvas
}

// runs is Runs at size 10, where a cell is 6 wide and a wide character 10.
func runs(value string, style ui.TextStyle) []ui.TextRun {
	return runsOnto(nil, value, style)
}

func runsOnto(dst []ui.TextRun, value string, style ui.TextStyle) []ui.TextRun {
	style.Size = 10
	got, _ := Runs(testCanvas(), dst, value, style)
	return got
}

func sameSpans(t *testing.T, got []ui.TextRun, want []span) {
	t.Helper()
	have := spans(got)
	if len(have) != len(want) {
		t.Fatalf("runs = %v, want %v", have, want)
	}
	for i := range want {
		if have[i] != want[i] {
			t.Fatalf("runs = %v, want %v", have, want)
		}
	}
}

func TestRunsKeepsASCIIInOneRun(t *testing.T) {
	sameSpans(t, runs(`"level": "INFO",`, ui.TextStyle{}), []span{{0, 16, 16}})
}

func TestRunsKeepsOtherCharactersTogether(t *testing.T) {
	// 日志 is two wide characters and … one narrow one: one stretch of five cells.
	sameSpans(t, runs(`a日志…b`, ui.TextStyle{}), []span{{0, 1, 1}, {1, 9, 5}, {6, 1, 1}})
	sameSpans(t, runs(`复制为 JSON`, ui.TextStyle{}), []span{{0, 9, 5}, {5, 5, 5}})
	sameSpans(t, runs(`日`, ui.TextStyle{}), []span{{0, 3, 2}})
	sameSpans(t, runs(`■`, ui.TextStyle{}), []span{{0, 3, 1}})
}

func TestRunsJoinsACombiningMarkToItsCharacter(t *testing.T) {
	// e followed by U+0301 COMBINING ACUTE ACCENT takes one cell.
	sameSpans(t, runs("cafe\u0301!", ui.TextStyle{}), []span{
		{0, 3, 3}, {3, 3, 1}, {4, 1, 1},
	})
	sameSpans(t, runs("e\u0301", ui.TextStyle{}), []span{{0, 3, 1}})
	sameSpans(t, runs("日\u0301", ui.TextStyle{}), []span{{0, 5, 2}})
	sameSpans(t, runs("日\u0301本", ui.TextStyle{}), []span{{0, 8, 4}})
	sameSpans(t, runs("xe\u0301日", ui.TextStyle{}), []span{{0, 1, 1}, {1, 6, 3}})
	// A mark with nothing before it has no cell of its own.
	sameSpans(t, runs("\u0301a", ui.TextStyle{}), []span{{0, 2, 0}, {0, 1, 1}})
}

func TestRunsSplitsLongASCII(t *testing.T) {
	value := strings.Repeat("x", maxASCIIRun+10)
	sameSpans(t, runs(value, ui.TextStyle{}), []span{
		{0, maxASCIIRun, maxASCIIRun}, {maxASCIIRun, 10, 10},
	})
}

func TestWidthIsTheCellsOfTheRuns(t *testing.T) {
	canvas := testCanvas()
	style := ui.TextStyle{Size: 10}
	for value, cells := range map[string]int{"": 0, "JSON": 4, "复制为 JSON": 10, "a日\u0301b": 4, "■ WARN": 6} {
		_, got := Runs(canvas, nil, value, style)
		if got != cells {
			t.Fatalf("Runs(%q) takes %d cells, want %d", value, got, cells)
		}
		if width := Width(canvas, value, style); width != float32(cells)*6 {
			t.Fatalf("Width(%q) = %v, want %v", value, width, float32(cells)*6)
		}
	}
}

func TestRunsCoverTheValue(t *testing.T) {
	for _, value := range []string{"", "plain", "a日\u0301 b…", "\tx", strings.Repeat("ab日", 200)} {
		total := int32(0)
		for _, run := range runs(value, ui.TextStyle{}) {
			total += run.Bytes
		}
		if int(total) != len(value) {
			t.Fatalf("runs of %q cover %d bytes, want %d", value, total, len(value))
		}
	}
}

func TestRunsCarryTheStyle(t *testing.T) {
	style := ui.TextStyle{Color: ui.Color{Red: 1, Alpha: 1}, Weight: 700, Italic: true}
	for _, run := range runs("a日b", style) {
		if run.Color != style.Color || run.Weight != style.Weight || !run.Italic {
			t.Fatalf("run %+v does not carry the style %+v", run, style)
		}
	}
}

func TestRunsAppendsToDst(t *testing.T) {
	head := []ui.TextRun{{Column: 9, Bytes: 9, Cells: 9}}
	got := runsOnto(head, "ab", ui.TextStyle{})
	sameSpans(t, got, []span{{9, 9, 9}, {0, 2, 2}})
}

func TestSnapPutsPlainMonoLabelsOnTheGrid(t *testing.T) {
	canvas := testCanvas()
	mono := ui.TextStyle{Size: 12, Mono: true}
	canvas.Label("before", ui.Rect{X: 0, Y: 0, Width: 40, Height: 14}, mono)
	from := len(canvas.Texts())
	canvas.Label(`"ok",`, ui.Rect{X: 10, Y: 20, Width: 40, Height: 14}, mono)
	canvas.Label("proportional", ui.Rect{X: 10, Y: 40, Width: 80, Height: 14}, ui.TextStyle{Size: 12})
	canvas.Label("", ui.Rect{X: 10, Y: 60, Width: 10, Height: 14}, mono)
	grid := []ui.TextRun{{Column: 0, Bytes: 3, Cells: 3}}
	canvas.LabelRuns("abc", ui.Rect{X: 10, Y: 80, Width: 30, Height: 14}, mono, 7, grid)
	before := append([]ui.Text(nil), canvas.Texts()...)

	Snap(canvas, from)

	texts := canvas.Texts()
	if len(texts) != len(before)+1 {
		t.Fatalf("Snap left %d texts, want the %d painted and one with nothing to draw", len(texts), len(before))
	}
	if texts[0] != before[0] {
		t.Fatalf("the label painted before from changed: %+v", texts[0])
	}
	snapped := texts[from]
	cell, _ := canvas.MonoCellSize(mono.Size, mono.MonoFace)
	if snapped.Value != `"ok",` || snapped.Bounds != before[from].Bounds || snapped.CellWidth != cell {
		t.Fatalf("snapped label = %+v, want its value and bounds on a %v cell", snapped, cell)
	}
	if snapped.Layer != before[from].Layer || snapped.ClipOf != before[from].ClipOf || snapped.HasClip != before[from].HasClip {
		t.Fatalf("snapped label moved off its layer or clip: %+v", snapped)
	}
	sameSpans(t, canvas.TextRuns(snapped), []span{{0, 5, 5}})
	for i := from + 1; i < len(before); i++ {
		if texts[i] != before[i] {
			t.Fatalf("text %d changed: %+v, was %+v", i, texts[i], before[i])
		}
	}
	added := texts[len(texts)-1]
	if added.Value != "" || added.RunCount != 0 || added.Bounds.Width > 0 {
		t.Fatalf("the line Snap added draws something: %+v", added)
	}
}

func TestRunsLetAStretchRunIntoTheCellAfterIt(t *testing.T) {
	// 复制为 is 30 wide at size 10, exactly five cells; 复制为导 is 40, six cells and two
	// thirds; 中 is 10, a cell and two thirds.
	canvas := new(ui.Canvas)
	canvas.SetMeasurer(func(value string, size, _ float32) float32 {
		width := float32(0)
		for _, r := range value {
			if text.CellWidth(r) == 2 {
				width += 1.02 * size
			} else {
				width += 0.6 * size
			}
		}
		return width
	})
	style := ui.TextStyle{Size: 10}
	cases := []struct {
		value string
		want  []span
	}{
		// 30.6 wide: a tenth of a cell over five. Before a space it keeps five cells and
		// runs into the space.
		{"复制为 JSON", []span{{0, 9, 5}, {5, 5, 5}}},
		// Before a letter a tenth of a cell is as far as it may go.
		{"复制为J", []span{{0, 9, 5}, {5, 1, 1}}},
		// At the end of the value it takes the sixth cell, so the box holds all of it.
		{"复制为", []span{{0, 9, 6}}},
		// 40.8 wide is 6.8 cells: before a space it may not run more than half a cell on.
		{"复制为导 x", []span{{0, 12, 7}, {7, 2, 2}}},
		// 10.2 wide is 1.7 cells: before a letter it takes the second cell.
		{"中x", []span{{0, 3, 2}, {2, 1, 1}}},
	}
	for _, c := range cases {
		got, _ := Runs(canvas, nil, c.value, style)
		sameSpans(t, got, c.want)
	}
}

func TestLinesBreakBetweenWordsOnTheCells(t *testing.T) {
	canvas := testCanvas()
	style := ui.TextStyle{Size: 10}
	lines := func(value string, cells int) []string {
		return Lines(canvas, nil, value, style, float32(cells)*6)
	}
	same := func(got, want []string) {
		t.Helper()
		if strings.Join(got, "|") != strings.Join(want, "|") || len(got) != len(want) {
			t.Fatalf("lines = %q, want %q", got, want)
		}
	}
	same(lines("fix(macos): one two", 12), []string{"fix(macos):", "one two"})
	same(lines("a  b", 12), []string{"a b"})
	same(lines("", 12), nil)
	same(lines("   ", 12), nil)
	// 复制为导 is 40 wide, seven cells, and 复制为导出 nine: a line of seven breaks the word
	// after 复制为导.
	same(lines("复制为导出", 7), []string{"复制为导", "出"})
	// The end of a broken word starts the line the next word joins.
	same(lines("复制为导出 x", 7), []string{"复制为导", "出 x"})
	// A word too long for any line takes a character a line.
	same(lines("日本", 1), []string{"日", "本"})
	// A combining mark stays with its character.
	same(lines("xe\u0301y", 2), []string{"xe\u0301", "y"})
	same(lines("abc", -1), []string{"a", "b", "c"})
	// A line breaks between two Chinese characters, so the first line is filled.
	same(lines("fix: 工具链选择", 9), []string{"fix: 工具", "链选择"})
	// A comma does not start a line: it goes down with the character before it.
	same(lines("工具，链", 4), []string{"工", "具，", "链"})
	// An opening bracket does not end a line.
	same(lines("构建（测试）", 4), []string{"构建", "（测", "试）"})
}

func TestLinesFitTheirWidth(t *testing.T) {
	canvas := testCanvas()
	style := ui.TextStyle{Size: 10}
	value := "fix(macos): #1495 工具链选择只把导出变量算作构建 provider 的贡献环境 (#1792)"
	for cells := 4; cells < 60; cells++ {
		width := float32(cells) * 6
		got := Lines(canvas, nil, value, style, width)
		for _, line := range got {
			if Width(canvas, line, style) > width {
				t.Fatalf("at %d cells the line %q is %v wide", cells, line, Width(canvas, line, style))
			}
		}
		if joined := strings.ReplaceAll(strings.Join(got, ""), " ", ""); joined != strings.ReplaceAll(value, " ", "") {
			t.Fatalf("at %d cells the lines %q lose characters", cells, got)
		}
	}
}
