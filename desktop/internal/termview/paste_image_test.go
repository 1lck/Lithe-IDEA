package termview

import (
	"errors"
	"testing"

	"github.com/vivaui/viva/app"
)

// A paste that finds no text asks PasteImage first. When it takes the paste nothing more is
// sent; when it declines, a program using bracketed paste gets the empty paste it waits for.
func TestPasteWithoutTextAsksForAPictureFirst(t *testing.T) {
	const emptyPaste = "\x1b[200~\x1b[201~"
	tests := []struct {
		name  string
		taken bool
		want  string
	}{
		{"taken", true, ""},
		{"declined", false, emptyPaste},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			rig := newFontRig(t)
			output(rig.view, &rig.shell.fakeShell, "\x1b[?2004h")
			asked := 0
			rig.view.cfg.PasteImage = func() bool { asked++; return test.taken }

			rig.view.terminalText(app.TextEvent{Kind: app.TextPasteNoText})
			if asked != 1 || string(rig.shell.input) != test.want {
				t.Fatalf("text-system paste: asked %d, sent %q, want once and %q", asked, rig.shell.input, test.want)
			}

			rig.shell.input = nil
			rig.view.cfg.Clipboard = func() (string, error) { return "", nil }
			rig.view.paste()
			if asked != 2 || string(rig.shell.input) != test.want {
				t.Fatalf("shortcut paste: asked %d, sent %q, want twice and %q", asked, rig.shell.input, test.want)
			}
		})
	}
}

// A clipboard that holds text pastes the text and never asks for a picture; one that cannot
// be read as text still has its picture looked for, and sends nothing when there is none.
func TestPasteAsksForAPictureOnlyWithoutText(t *testing.T) {
	rig := newFontRig(t)
	asked := 0
	rig.view.cfg.PasteImage = func() bool { asked++; return false }

	rig.view.cfg.Clipboard = func() (string, error) { return "ls", nil }
	rig.view.paste()
	if asked != 0 || string(rig.shell.input) != "ls" {
		t.Fatalf("text paste: asked %d, sent %q", asked, rig.shell.input)
	}

	rig.shell.input = nil
	rig.view.cfg.Clipboard = func() (string, error) { return "", errors.New("no text flavor") }
	rig.view.paste()
	if asked != 1 || len(rig.shell.input) != 0 {
		t.Fatalf("unreadable clipboard: asked %d, sent %q", asked, rig.shell.input)
	}
}

// A view whose program has ended has nowhere to type a path, so it offers nothing.
func TestEndedTerminalOffersNoPicturePaste(t *testing.T) {
	rig := newFontRig(t)
	asked := 0
	rig.view.cfg.PasteImage = func() bool { asked++; return true }
	rig.view.shell = nil
	rig.view.terminalText(app.TextEvent{Kind: app.TextPasteNoText})
	if asked != 0 {
		t.Fatalf("an ended terminal asked for a picture %d times", asked)
	}
}
