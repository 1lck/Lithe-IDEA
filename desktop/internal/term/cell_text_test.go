package term

import "testing"

func TestAppendCellTextReadsAnExactRangeOfCells(t *testing.T) {
	screen := New(20, 4, 0)
	screen.Write([]byte("$ ls 世界x"))
	for _, testCase := range []struct {
		name     string
		from, to int
		want     string
		ok       bool
	}{
		{"whole text", 0, 10, "$ ls 世界x", true},
		{"prompt only", 0, 2, "$ ", true},
		{"empty range", 3, 3, "", true},
		{"a wide character", 5, 7, "世", true},
		{"unwritten cells read as spaces", 9, 12, "x  ", true},
		{"starts inside a wide character", 6, 9, "", false},
		{"ends inside a wide character", 4, 6, "", false},
		{"past the row", 0, 21, "", false},
		{"backwards", 5, 2, "", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			got, ok := screen.AppendCellText(nil, 0, testCase.from, testCase.to)
			if ok != testCase.ok || string(got) != testCase.want {
				t.Fatalf("[%d,%d) = %q (ok %v), want %q (ok %v)", testCase.from, testCase.to, got, ok, testCase.want, testCase.ok)
			}
		})
	}
	if _, ok := screen.AppendCellText(nil, 4, 0, 1); ok {
		t.Fatal("a row below the screen was read")
	}
}
