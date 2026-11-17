package localshell

import (
	"slices"
	"strings"
	"testing"
)

func TestPromptMarksFindTheSessionsMarksInPiecesOfOutput(t *testing.T) {
	const output = "\x1b]133;A;motty=tok\a$ \x1b]133;B;motty=tok\aecho hi\r\n" +
		"\x1b]133;C;motty=tok\ahi\r\n\x1b]133;D;0;motty=tok\a\x1b]133;D;127;motty=tok\a"
	want := []byte("ABCDD")
	for _, size := range []int{1, 2, 3, 7, len(output)} {
		marks := newPromptMarks("tok")
		var seen []byte
		for start := 0; start < len(output); start += size {
			marks.feed([]byte(output[start:min(start+size, len(output))]), func(kind byte) { seen = append(seen, kind) })
		}
		if !slices.Equal(seen, want) {
			t.Errorf("pieces of %d: marks = %q, want %q", size, seen, want)
		}
	}
}

func TestPromptMarksIgnoreOtherMarksAndOutput(t *testing.T) {
	for _, output := range []string{
		"\x1b]133;B;motty=other\a",                               // another session's token
		"\x1b]133;B\a",                                           // a program's own mark, without a token
		"\x1b]133;B;motty=tokx\a",                                // a longer token
		"\x1b]133;A;0;motty=tok\a",                               // only D carries a status
		"\x1b]133;E;motty=tok\a",                                 // not a prompt mark
		"\x1b]134;B;motty=tok\a",                                 // another OSC
		"\x1b]133;B;motty=\x1btok\a",                             // an escape inside ends the mark
		"\x1b]133;D;" + strings.Repeat("9", 64) + ";motty=tok\a", // too long to be a status
		"\x1b[31m\x1b]0;title\a plain text",
	} {
		marks := newPromptMarks("tok")
		marks.feed([]byte(output), func(kind byte) { t.Errorf("%q: found mark %q", output, kind) })
	}
}

func TestPromptMarksRestartAtAnEscapeThatInterruptsAMark(t *testing.T) {
	marks := newPromptMarks("tok")
	var seen []byte
	marks.feed([]byte("\x1b]13\x1b]133;B;mo\x1b]133;C;motty=tok\a"), func(kind byte) { seen = append(seen, kind) })
	if string(seen) != "C" {
		t.Fatalf("marks = %q, want C", seen)
	}
}

func TestPromptMarksNeedAToken(t *testing.T) {
	if newPromptMarks("") != nil {
		t.Fatal("a shell without a token follows no marks")
	}
}
