package termview

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
)

// newOutputView is a started view on a fake shell whose screen is cols by rows, so a test
// can make output scroll it with a few lines.
func newOutputView(t *testing.T, cols, rows int) (*View, *fakeShell) {
	t.Helper()
	var started localshell.Config
	shell := &fakeShell{done: make(chan struct{})}
	view := newFakeView(shell, Config{Shell: "tool", Args: []string{}}, &started)
	t.Cleanup(func() { view.Close() })
	view.ensureStarted()
	view.screen.Resize(cols, rows)
	return view, shell
}

// output hands text to the view as the program's output and parses it.
func output(view *View, shell *fakeShell, text string) {
	shell.output = append(shell.output, text...)
	view.Pump()
}

// Output that scrolls the screen leaves the selection on the text it was made on, so a
// stream of output does not make the terminal's text impossible to copy.
func TestOutputKeepsTheSelectionOnItsText(t *testing.T) {
	view, shell := newOutputView(t, 20, 4)
	output(view, shell, "alpha beta\r\ngamma\r\n")
	view.selection.selectRange(
		view.screen.PointAt(term.Position{Row: 0, Column: 0}),
		view.screen.PointAt(term.Position{Row: 1, Column: 4}),
	)
	output(view, shell, "delta\r\nepsilon\r\nzeta\r\neta\r\ntheta\r\n")
	if !view.HasSelection() {
		t.Fatal("output cleared the selection")
	}
	if got := view.SelectionText(); got != "alpha beta\ngamma" {
		t.Fatalf("selection copied %q after output, want the text it was made on", got)
	}
}

// The shell printing while the button is held does not end the drag: the rest of it still
// selects from where the press was.
func TestOutputDoesNotBreakASelectionDrag(t *testing.T) {
	rig := newFontRig(t)
	output(rig.view, &rig.shell.fakeShell, "alpha beta\r\ngamma delta\r\n")
	rig.paint()
	at := func(row, column int) (float32, float32) {
		layout := rig.view.layout
		return layout.left + (float32(column)+0.5)*rig.view.cellW, layout.top + (float32(row)+0.5)*rig.view.rowH
	}
	hit := rig.view.cfg.HitID
	x, y := at(0, 2)
	rig.view.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, Target: hit, X: x, Y: y})
	output(rig.view, &rig.shell.fakeShell, "one\r\ntwo\r\n")
	if !rig.view.selection.dragging {
		t.Fatal("output ended the drag")
	}
	x, y = at(0, 8)
	rig.view.Pointer(gfx.PointerEvent{Kind: gfx.PointerMove, Button: gfx.PointerButtonPrimary, Target: hit, Captured: true, X: x, Y: y})
	rig.view.Pointer(gfx.PointerEvent{Kind: gfx.PointerUp, Button: gfx.PointerButtonPrimary, Target: hit, Captured: true, X: x, Y: y})
	if got := rig.view.SelectionText(); got != "pha bet" {
		t.Fatalf("drag selected %q across output, want %q", got, "pha bet")
	}
}

// A selection follows the scrollback as it drops its oldest lines: losing its first line
// moves its start to the oldest line still kept, and losing its last line drops it.
func TestOutputTrimsASelectionTheScrollbackDropped(t *testing.T) {
	view, shell := newOutputView(t, 20, 3)
	view.screen.SetScrollbackLimit(2)
	// The screen scrolls once: keep goes to the history, drop and more stay on the screen.
	output(view, shell, "keep\r\ndrop\r\nmore\r\n")
	view.selection.selectRange(
		view.screen.PointAt(term.Position{Row: 0, Column: 0}),
		view.screen.PointAt(term.Position{Row: 1, Column: 3}),
	)
	if got := view.SelectionText(); got != "drop\nmore" {
		t.Fatalf("selection = %q before any line was dropped", got)
	}
	// Three more lines push drop out of the two-line history; more is the oldest kept.
	output(view, shell, "x\r\ny\r\nz\r\n")
	if !view.HasSelection() {
		t.Fatal("dropping the selection's first line cleared all of it")
	}
	if got := view.SelectionText(); got != "more" {
		t.Fatalf("selection after its first line was dropped = %q, want %q", got, "more")
	}
	// The next line pushes more out too, the last line the selection covered.
	output(view, shell, "w\r\n")
	if view.HasSelection() {
		t.Fatalf("selection outlived its text: %q", view.SelectionText())
	}
}

// What makes the selection's line numbers name other text still drops it: the alternate
// screen, a reset and clearing the screen.
func TestBufferChangesClearASelection(t *testing.T) {
	for _, test := range []struct {
		name   string
		output string
	}{
		{"alternate screen", "\x1b[?1049h"},
		{"leaving the alternate screen", "\x1b[?1049l"},
		{"reset", "\x1bc"},
	} {
		t.Run(test.name, func(t *testing.T) {
			view, shell := newOutputView(t, 20, 4)
			if test.name == "leaving the alternate screen" {
				output(view, shell, "\x1b[?1049h")
			}
			output(view, shell, "alpha beta\r\n")
			view.selection.selectRange(
				view.screen.PointAt(term.Position{Row: 0, Column: 0}),
				view.screen.PointAt(term.Position{Row: 0, Column: 4}),
			)
			output(view, shell, test.output)
			if view.HasSelection() {
				t.Fatalf("selection survived %s: %q", test.name, view.SelectionText())
			}
		})
	}
}

// Clear starts a new buffer generation itself. A selection made after it is on the cleared
// buffer, so the next output must not take the clear for a change made under it.
func TestASelectionMadeAfterClearSurvivesOutput(t *testing.T) {
	view, shell := newOutputView(t, 20, 4)
	output(view, shell, "old\r\nprompt$ ls")
	view.Clear()
	// The prompt line is all the clear keeps; it is selected before anything else is
	// printed, so no output has seen the clear's generation yet.
	view.selection.selectRange(
		view.screen.PointAt(term.Position{Row: 0, Column: 0}),
		view.screen.PointAt(term.Position{Row: 0, Column: 5}),
	)
	output(view, shell, "\r\nalpha\r\n")
	if got := view.SelectionText(); got != "prompt" {
		t.Fatalf("selection after Clear copied %q once output arrived, want %q", got, "prompt")
	}
}
