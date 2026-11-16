package settingswindow

import (
	"slices"
	"strconv"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/app"
)

// terminalResetWindow isolates the settings owner and shell facts; no real preferences or
// shell process are read or changed by these window interactions.
func terminalResetWindow(values Values, language i18n.Language, dark bool, scrollbacks *[]int, cursors *[][2]string) *window {
	w := newWindow(NewController(Options{
		Text:     func() *i18n.Messages { return i18n.For(language) },
		Language: func() i18n.Language { return language }, SystemLanguage: language,
		SystemDark:            func() bool { return dark },
		TerminalShells:        func() ([]localshell.Choice, string) { return nil, "" },
		SetTerminalScrollback: func(lines int) { *scrollbacks = append(*scrollbacks, lines) },
		SetTerminalCursor:     func(shape, thickness string) { *cursors = append(*cursors, [2]string{shape, thickness}) },
	}), values)
	w.sess.page = pageTerminal
	return w
}

func assertTerminalDefaults(t *testing.T, w *window, d *windowDriver, scrollbacks []int, cursors [][2]string) {
	t.Helper()
	if !slices.Equal(scrollbacks, []int{DefaultScrollback}) || !slices.Equal(cursors, [][2]string{{CursorShapeBlock, CursorThicknessNormal}}) {
		t.Fatalf("reset owner callbacks: scrollback=%v cursor=%v", scrollbacks, cursors)
	}
	if w.sess.values.TerminalScrollback != DefaultScrollback || w.sess.values.TerminalCursorShape != CursorShapeBlock || w.sess.values.TerminalCursorThickness != CursorThicknessNormal {
		t.Fatalf("reset left stored values: scrollback=%d cursor=%q/%q", w.sess.values.TerminalScrollback, w.sess.values.TerminalCursorShape, w.sess.values.TerminalCursorThickness)
	}
	word := func(key string) string { return i18n.Shared(w.marketLanguage(), "desktop.settings.terminal."+key) }
	if got := d.hit(word("scrollback")).Value; got != strconv.Itoa(DefaultScrollback) {
		t.Fatalf("scrollback field = %q", got)
	}
	if got := d.hit(word("cursorShape")).Value; got != word("cursorShapeBlock") {
		t.Fatalf("cursor shape = %q", got)
	}
	if got := d.hit(word("cursorThickness")).Value; got != word("cursorNormal") {
		t.Fatalf("cursor thickness = %q", got)
	}
}

// The actual footer action must notify the settings owner even when an unknown stored
// cursor or implicit history default already renders as the default on screen.
func TestTerminalRestoreDefaultsReachesOwnerAndPage(t *testing.T) {
	for _, scenario := range []struct {
		name   string
		values Values
	}{
		{"non-default", Values{TerminalScrollback: 50000, TerminalCursorShape: CursorShapeBar, TerminalCursorThickness: CursorThicknessThick}},
		{"unknown-stored", Values{TerminalScrollback: 0, TerminalCursorShape: "future-shape", TerminalCursorThickness: "future-thickness"}},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			var scrollbacks []int
			var cursors [][2]string
			w := terminalResetWindow(scenario.values, i18n.English, false, &scrollbacks, &cursors)
			d := openWindow(t, w, func(c *app.Config) { c.Height = 1000 })
			if len(scrollbacks) != 0 || len(cursors) != 0 {
				t.Fatal("opening the page changed settings")
			}
			d.click(w.text.Settings.RestoreDefaults)
			d.pump()
			assertTerminalDefaults(t, w, d, scrollbacks, cursors)
			// Repainting and closing must not replay the reset or restore the old values.
			d.pump()
			d.click(w.text.Settings.Cancel)
			if len(scrollbacks) != 1 || len(cursors) != 1 {
				t.Fatalf("close/repaint wrote again: %v %v", scrollbacks, cursors)
			}
			w.scrollbackField.SetText("45000")
			w.commitScrollback()
			if len(scrollbacks) != 1 {
				t.Fatal("closed window applied a late history edit")
			}
		})
	}
}

func TestTerminalUnchangedChoicesDoNotWrite(t *testing.T) {
	var scrollbacks []int
	var cursors [][2]string
	w := terminalResetWindow(Values{TerminalScrollback: DefaultScrollback}, i18n.English, false, &scrollbacks, &cursors)
	d := openWindow(t, w, func(c *app.Config) { c.Height = 1000 })
	word := func(key string) string { return i18n.Shared(w.marketLanguage(), "desktop.settings.terminal."+key) }
	d.click(word("cursorShape"))
	d.click(word("cursorShapeBlock"))
	d.click(word("cursorThickness"))
	d.click(word("cursorNormal"))
	w.scrollbackField.SetText(strconv.Itoa(DefaultScrollback))
	w.commitScrollback()
	d.pump()
	if len(scrollbacks) != 0 || len(cursors) != 0 {
		t.Fatalf("unchanged choices wrote: %v %v", scrollbacks, cursors)
	}
}

// Losing focus can commit a draft before the reset click is handled. Once reset wins,
// subsequent paints or focus changes must not resurrect that old draft.
func TestTerminalRestoreDoesNotReviveScrollbackDraft(t *testing.T) {
	var scrollbacks []int
	var cursors [][2]string
	w := terminalResetWindow(Values{TerminalScrollback: 50000}, i18n.English, false, &scrollbacks, &cursors)
	d := openWindow(t, w, func(c *app.Config) { c.Height = 1000 })
	label := i18n.Shared(w.marketLanguage(), "desktop.settings.terminal.scrollback")
	d.click(label)
	// Inject an in-progress field draft; input-method delivery is outside this reset test.
	w.scrollbackEditing = true
	w.scrollbackField.SetText("45000")
	d.pump()
	if !w.scrollbackEditing {
		t.Fatal("history field did not enter its draft state")
	}
	d.click(w.text.Settings.RestoreDefaults)
	d.pump()
	if len(scrollbacks) == 0 || scrollbacks[len(scrollbacks)-1] != DefaultScrollback || w.sess.values.TerminalScrollback != DefaultScrollback || w.scrollbackEditing {
		t.Fatalf("reset did not replace the draft: calls=%v stored=%d editing=%v", scrollbacks, w.sess.values.TerminalScrollback, w.scrollbackEditing)
	}
	count := len(scrollbacks)
	d.click(label)
	d.click(w.text.Settings.RestoreDefaults)
	// A second explicit reset is allowed to notify once again, but not to publish old input.
	for _, lines := range scrollbacks[count:] {
		if lines != DefaultScrollback {
			t.Fatalf("old draft returned after reset: %v", scrollbacks)
		}
	}
	d.pump()
	if got := d.hit(label).Value; got != strconv.Itoa(DefaultScrollback) {
		t.Fatalf("field after reset = %q", got)
	}
}
