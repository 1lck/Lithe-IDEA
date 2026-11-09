package monogrid

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// testStyle is a Mono style whose cell, on a canvas with no fonts, is 6 wide: a character
// takes one cell, a wide one two.
var testStyle = gfx.TextStyle{Size: 10, Mono: true}

func TestLinesBreakBetweenWordsOnTheCells(t *testing.T) {
	canvas := new(gfx.Canvas)
	cell, _ := canvas.MonoCellSize(testStyle.Size, testStyle.MonoFace)
	lines := func(value string, cells int) []string {
		return Lines(canvas, nil, value, testStyle, float32(cells)*cell)
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
	// A Chinese character takes two cells, so a line of seven holds three of them.
	same(lines("复制为导出", 7), []string{"复制为", "导出"})
	// The end of a broken word starts the line the next word joins.
	same(lines("复制为导出 x", 7), []string{"复制为", "导出 x"})
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
	canvas := new(gfx.Canvas)
	cell, _ := canvas.MonoCellSize(testStyle.Size, testStyle.MonoFace)
	value := "fix(macos): #1495 工具链选择只把导出变量算作构建 provider 的贡献环境 (#1792)"
	for cells := 4; cells < 60; cells++ {
		width := float32(cells) * cell
		got := Lines(canvas, nil, value, testStyle, width)
		for _, line := range got {
			if drawn := canvas.TextWidthStyle(line, testStyle); drawn > width {
				t.Fatalf("at %d cells the line %q is %v wide", cells, line, drawn)
			}
		}
		if joined := strings.ReplaceAll(strings.Join(got, ""), " ", ""); joined != strings.ReplaceAll(value, " ", "") {
			t.Fatalf("at %d cells the lines %q lose characters", cells, got)
		}
	}
}

// Lines measures value as a Mono label even when style does not say so.
func TestLinesMeasureOnTheCells(t *testing.T) {
	canvas := new(gfx.Canvas)
	cell, _ := canvas.MonoCellSize(testStyle.Size, testStyle.MonoFace)
	plain := testStyle
	plain.Mono = false
	got := Lines(canvas, nil, "工具链", plain, 4*cell)
	if strings.Join(got, "|") != "工具|链" {
		t.Fatalf("lines = %q, want 工具 and 链", got)
	}
}
