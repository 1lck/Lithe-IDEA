package term

import (
	"strings"
	"testing"
)

// TestTextRunsMatchTheBytePath feeds text through the run path and the same
// text a byte at a time through the state machine, then checks the grid, the
// combining marks and the cursor came out the same.
func TestTextRunsMatchTheBytePath(t *testing.T) {
	texts := []string{
		"plain ascii",
		"中文输出和 mixed English 文字，",
		"日本語のテキスト",
		"全角ＡＢＣ and emoji 🙂🙂",
		"combining e\u0301 a\u0300 中\u0301",
		strings.Repeat("中", 40),
		strings.Repeat("字", 7) + "tail",
		"wrap 中文 中文 中文 中文 中文 中文 中文",
		"truncated 中",
		"invalid \xff byte",
		"control\ttab\x7fdel",
		"\x1b[44mstyled 中文\x1b[0m plain",
		"中\x1b[1;2Habc",
		"中\x1b[1;2H中文",
		"中文\x1b[1;4Hxy",
		"中中中\x1b[1;3Habcdef",
		// The run stops on the head of a wide character: the repair of the half it
		// leaves behind happens after the write and has nothing else to catch it.
		"中文\x1b[1;1H\u00e9",
		"中文\x1b[1;2H\u00e9x",
		// One write longer than the run buffer keeps decoding the remainder on the
		// state machine, so the boundary is covered.
		strings.Repeat("\u00e9", 5000),
	}
	for _, cols := range []int{20, 21, 2, 1} {
		for _, text := range texts {
			runs := New(cols, 6, 4)
			runs.Write([]byte(text))
			bytewise := New(cols, 6, 4)
			for index := 0; index < len(text); index++ {
				bytewise.feed(text[index])
			}
			bytewise.version++
			compareGrid(t, text, cols, runs, bytewise)
		}
	}
}

// compareGrid fails when two terminals that were fed the same text disagree.
func compareGrid(t *testing.T, text string, cols int, runs, bytewise *Terminal) {
	t.Helper()
	if runs.Cursor() != bytewise.Cursor() {
		t.Fatalf("%d cols, %q: cursor %+v, byte path %+v", cols, text, runs.Cursor(), bytewise.Cursor())
	}
	if runs.histCount != bytewise.histCount {
		t.Fatalf("%d cols, %q: %d history lines, byte path %d", cols, text, runs.histCount, bytewise.histCount)
	}
	for y := 0; y < runs.rows; y++ {
		got, want := runs.Row(y), bytewise.Row(y)
		if len(got.Cells) != len(want.Cells) {
			t.Fatalf("%d cols, %q: row %d has %d cells, byte path %d",
				cols, text, y, len(got.Cells), len(want.Cells))
		}
		for x := range want.Cells {
			if got.Cells[x] != want.Cells[x] {
				t.Fatalf("%d cols, %q: row %d cell %d = %+v, byte path %+v",
					cols, text, y, x, got.Cells[x], want.Cells[x])
			}
		}
		if len(got.Marks) != len(want.Marks) {
			t.Fatalf("%d cols, %q: row %d has %d marks, byte path %d", cols, text, y, len(got.Marks), len(want.Marks))
		}
		for index := range want.Marks {
			if got.Marks[index] != want.Marks[index] {
				t.Fatalf("%d cols, %q: row %d mark %d = %+v, byte path %+v",
					cols, text, y, index, got.Marks[index], want.Marks[index])
			}
		}
	}
}
