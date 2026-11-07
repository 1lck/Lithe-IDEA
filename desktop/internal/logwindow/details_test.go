package logwindow

import (
	"reflect"
	"strings"
	"testing"
)

func TestWrapDetailWordsCountsWideCharactersAsTwoCells(t *testing.T) {
	got := wrapDetailWords("‹redacted› 的值已由 Core 脱敏", 10)
	want := []string{"‹redacted›", "的值已由", "Core 脱敏"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("wrapDetailWords = %q, want %q", got, want)
	}
	for _, line := range got {
		if cells := monoCells(line); cells > 10 {
			t.Fatalf("line %q takes %d cells, more than 10", line, cells)
		}
	}
}

func TestWrapDetailWordsBreaksAWordLongerThanALine(t *testing.T) {
	got := wrapDetailWords("abcdefgh 窗口和导出都不会显示", 5)
	want := []string{"abcde", "fgh", "窗口", "和导", "出都", "不会", "显示"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("wrapDetailWords = %q, want %q", got, want)
	}
}

func TestWrapDetailRowKeepsEveryRowWithinTheCells(t *testing.T) {
	line := detailRow{{text: `"msg": `, role: detailKey}, {text: `"工作区打开失败，请检查目录"`, role: detailString}}
	rows := wrapDetailRow(line, 9)
	var joined strings.Builder
	for _, row := range rows {
		cells := 0
		for _, span := range row {
			cells += monoCells(span.text)
			joined.WriteString(span.text)
		}
		if cells > 9 {
			t.Fatalf("row %v takes %d cells, more than 9", row, cells)
		}
	}
	if want := `"msg": "工作区打开失败，请检查目录"`; joined.String() != want {
		t.Fatalf("rows join to %q, want %q", joined.String(), want)
	}
}

func TestWrapDetailRowGivesACharacterWiderThanARowARowOfItsOwn(t *testing.T) {
	rows := wrapDetailRow(detailRow{{text: "a中b", role: detailString}}, 1)
	var got []string
	for _, row := range rows {
		var text strings.Builder
		for _, span := range row {
			text.WriteString(span.text)
		}
		got = append(got, text.String())
	}
	if want := []string{"a", "中", "b"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("rows = %q, want %q", got, want)
	}
}
