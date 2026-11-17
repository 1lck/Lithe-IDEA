package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
	"github.com/vivaui/viva/ui"
)

// unboundAction is the first action of the catalog without default keys, and a chord that no
// action holds by default, so a test can record one for the other. The defaults differ by
// platform (Control-Alt-Shift-J selects all occurrences outside macOS), so the chord is the
// first free Control-Alt-Shift letter of the running platform's catalog.
func unboundAction(t *testing.T) (shortcuts.Action, keymap.Chord) {
	t.Helper()
	chord, found := keymap.Chord{}, false
	for char := byte('a'); char <= 'z' && !found; char++ {
		chord = keymap.Chord{Modifiers: gfx.ModifierControl | gfx.ModifierAlt | gfx.ModifierShift, Char: char}
		_, taken := shortcuts.Overrides(nil).Owner(chord, "")
		found = !taken && shortcuts.Bindable(chord)
	}
	if !found {
		t.Fatal("every Control-Alt-Shift letter is held by a default shortcut")
	}
	for _, action := range shortcuts.All() {
		if len(shortcuts.Overrides(nil).Effective(action)) == 0 {
			return action, chord
		}
	}
	t.Fatal("every action has default keys")
	return shortcuts.Action{}, chord
}

// rowControl is the control labeled label in the row of action on the Keymap page.
func (d *windowDriver) rowControl(action shortcuts.Action, label string) gfx.Hit {
	d.t.Helper()
	row := d.hit(action.Title(d.w.text)).Bounds
	for _, hit := range d.driver.Snapshot().Hits {
		mid := hit.Bounds.Y + hit.Bounds.Height/2
		if hit.Label == label && !hit.IsLabel && !hit.ID.IsZero() && mid >= row.Y && mid <= row.Y+row.Height {
			return hit
		}
	}
	d.t.Fatalf("no %q in the row of %s", label, action.ID)
	return gfx.Hit{}
}

// Clicking Add Shortcut on a row and pressing a chord with modifiers adds the chord to the
// action: the recorder takes the keys itself, so a chord reaches it instead of a text field's
// text system, and Escape ends recording without cancelling the window.
func TestKeymapAddRecordsTheChordPressedAfterIt(t *testing.T) {
	action, chord := unboundAction(t)
	var set []shortcuts.Overrides
	w := newWindow(NewController(Options{SetKeymap: func(value shortcuts.Overrides) { set = append(set, value) }}), Values{})
	w.sess.page = pageKeymap
	d := openWindow(t, w)
	d.pump()

	d.clickHit(d.rowControl(action, w.text.Keymap.Add))
	d.pump()
	if w.keymap.recording != action.ID {
		t.Fatalf("recording %q after Add, want %q", w.keymap.recording, action.ID)
	}
	if err := d.driver.Chord(chord.Modifiers, string(chord.Char)); err != nil {
		t.Fatal(err)
	}
	d.pump()
	if len(set) != 1 || !set[0].Changed(action.ID) {
		t.Fatalf("keymap writes %+v, want %s added to %s", set, chord.Label(), action.ID)
	}
	if got := set[0].Effective(action); len(got) != 1 || got[0] != chord {
		t.Fatalf("%s has %v, want [%s]", action.ID, got, chord.Label())
	}
	if w.keymap.recording != "" {
		t.Fatalf("still recording %q after a chord was taken", w.keymap.recording)
	}

	d.clickHit(d.rowControl(action, w.text.Keymap.Add))
	d.pump()
	d.key(gfx.KeyEscape)
	d.pump()
	if w.keymap.recording != "" || w.sess.finished.Load() {
		t.Fatalf("Escape left recording %q and closed the window %v; want recording ended, window open", w.keymap.recording, w.sess.finished.Load())
	}

	// The window's own Close chord is the recording's while it records.
	d.clickHit(d.rowControl(action, w.text.Keymap.Add))
	d.pump()
	if err := d.driver.Chord(ui.Primary, "w"); err != nil {
		t.Fatal(err)
	}
	d.pump()
	if w.sess.finished.Load() {
		t.Fatal("Primary+W closed the window while a shortcut was being recorded")
	}
}

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

// Search Everywhere's row on the Keymap page shows the Double Shift gesture beside its
// chords, and the filter finds the action by the gesture.
func TestKeymapShowsTheDoubleShiftGestureOfSearchEverywhere(t *testing.T) {
	action, ok := shortcuts.Find("search.everywhere")
	if !ok || action.Gesture != shortcuts.DoubleShiftLabel() {
		t.Fatalf("search.everywhere has gesture %q, want %q", action.Gesture, shortcuts.DoubleShiftLabel())
	}
	w := newWindow(NewController(Options{}), Values{})
	w.sess.page = pageKeymap
	// Filtering by the gesture brings the row into view.
	w.keymap.query.SetText(action.Gesture)
	d := openWindow(t, w)
	d.pump()
	row := d.hit(action.Title(w.text)).Bounds
	found := false
	for _, label := range d.driver.Snapshot().Labels {
		mid := label.Bounds.Y + label.Bounds.Height/2
		if label.Value == action.Gesture && mid >= row.Y && mid <= row.Y+row.Height {
			found = true
		}
	}
	if !found {
		t.Fatalf("no %q in the row of %s", action.Gesture, action.ID)
	}
}
