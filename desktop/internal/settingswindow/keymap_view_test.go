package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
)

// The context menu of an action's row on the Keymap page restores its default keys and starts
// recording a new chord, as the earlier client's keymap did.
func TestKeymapRowMenuRestoresTheDefaultAndAddsAShortcut(t *testing.T) {
	action := shortcuts.All()[0]
	var set []shortcuts.Overrides
	w := newWindow(NewController(Options{SetKeymap: func(value shortcuts.Overrides) { set = append(set, value) }}),
		Values{Keymap: shortcuts.Overrides(nil).With(action.ID, nil)})
	w.sess.page = pageKeymap
	d := openWindow(t, w)
	d.pump()
	rightClick := func() {
		t.Helper()
		bounds := d.hit(action.Title(w.text)).Bounds
		if err := d.driver.ClickButton(bounds.X+bounds.Width/2, bounds.Y+bounds.Height/2, gfx.PointerButtonSecondary); err != nil {
			t.Fatal(err)
		}
		d.pump()
	}

	rightClick()
	d.click(w.text.Keymap.RestoreDefault)
	d.pump()
	if len(set) != 1 || set[0].Changed(action.ID) {
		t.Fatalf("keymap writes %+v, want the action's default restored", set)
	}
	rightClick()
	if d.has(w.text.Keymap.RestoreDefault) {
		t.Fatal("Restore Default is offered for an action that has its default keys")
	}
	d.click(w.text.Keymap.Add)
	d.pump()
	if w.keymap.recording != action.ID {
		t.Fatalf("recording %q, want %q", w.keymap.recording, action.ID)
	}
}
