package editorview

import (
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/vivaui/viva/gfx"
)

// applyLSPEdit applies edit, a range in lines and UTF-16 columns as OnEdit reports it, to text
// and returns the result. It is how a language server follows the view.
func applyLSPEdit(t *testing.T, text string, edit Edit) string {
	t.Helper()
	offset := func(line, column int) int {
		lines := strings.SplitAfter(text, "\n")
		if line >= len(lines) {
			t.Fatalf("line %d is past the %d lines of the text", line, len(lines))
		}
		at := 0
		for _, l := range lines[:line] {
			at += len(l)
		}
		units := 0
		for i, r := range lines[line] {
			if units >= column {
				return at + i
			}
			units++
			if r > 0xffff {
				units++
			}
		}
		return at + len(lines[line])
	}
	start := offset(edit.StartLine, edit.StartColumn)
	end := offset(edit.EndLine, edit.EndColumn)
	return text[:start] + edit.Text + text[end:]
}

func newEditRecordingView(t *testing.T, text string) (*View, *[]Edit) {
	t.Helper()
	var edits []Edit
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte(text)), OnEdit: func(edit Edit) { edits = append(edits, edit) }})
	t.Cleanup(v.Close)
	return v, &edits
}

func TestReloadReportsOnlyTheChangedRange(t *testing.T) {
	old := "alpha\nbeta 😀 gamma\ndelta\nepsilon\n"
	disk := "alpha\nbeta 😀 GAMMA\ndelta\nepsilon\n"
	v, edits := newEditRecordingView(t, old)
	content := PrepareAgainst(v.SavedSnapshot(), []byte(disk))
	if !v.Reload(content) {
		t.Fatal("clean document did not reload")
	}
	if got := v.contents(); got != disk {
		t.Fatalf("reloaded %q, want %q", got, disk)
	}
	if len(*edits) != 1 {
		t.Fatalf("edits = %+v, want one range edit", *edits)
	}
	if got := applyLSPEdit(t, old, (*edits)[0]); got != disk {
		t.Fatalf("applying the reported edit to the old text gave %q, want %q (edit %+v)", got, disk, (*edits)[0])
	}
	if e := (*edits)[0]; e.StartLine != 1 || e.EndLine != 1 {
		t.Fatalf("the edit covers lines %d to %d, want only line 1: a reload reports the bytes that changed", e.StartLine, e.EndLine)
	}
}

func TestReloadWithNoChangeReportsNothing(t *testing.T) {
	v, edits := newEditRecordingView(t, "same\ntext\n")
	if !v.Reload(PrepareAgainst(v.SavedSnapshot(), []byte("same\ntext\n"))) {
		t.Fatal("clean document did not reload")
	}
	if len(*edits) != 0 {
		t.Fatalf("an identical reload reported %+v", *edits)
	}
}

func TestResolveWithDiskMeasuresAgainstTheEditedText(t *testing.T) {
	v, edits := newEditRecordingView(t, "one\ntwo\nthree\n")
	if !v.GoToNavigation(1, 0, false) {
		t.Fatal("navigation refused")
	}
	v.typeText("local ")
	local := v.contents()
	// The conflict path prepares against the text the view holds when it starts.
	disk := "one\ntwo changed\nthree\n"
	content := PrepareAgainst(v.TextSnapshot(), []byte(disk))
	*edits = nil
	if !v.ResolveWithDisk(content) {
		t.Fatal("conflict resolution refused")
	}
	if len(*edits) != 1 {
		t.Fatalf("edits = %+v, want one range edit", *edits)
	}
	if got := applyLSPEdit(t, local, (*edits)[0]); got != disk {
		t.Fatalf("applying the reported edit to the edited text gave %q, want %q", got, disk)
	}
}

func TestResolveWithDiskWithUnrelatedBaseStillReportsTheChange(t *testing.T) {
	v, edits := newEditRecordingView(t, "keep\nthis\n")
	// Prepared against a text the view does not hold: the change is measured again on apply.
	other := rope.FromString("something else entirely\n")
	disk := "keep\nthat\n"
	content := PrepareAgainst(other, []byte(disk))
	if !v.ResolveWithDisk(content) {
		t.Fatal("conflict resolution refused")
	}
	if len(*edits) != 1 {
		t.Fatalf("edits = %+v, want one range edit", *edits)
	}
	if got := applyLSPEdit(t, "keep\nthis\n", (*edits)[0]); got != disk {
		t.Fatalf("applying the reported edit gave %q, want %q", got, disk)
	}
}
