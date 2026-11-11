package settingswindow

import (
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
	"github.com/vivaui/viva/ui"
)

// keymapRecordID is the field that takes the keys of a chord being recorded.
var keymapRecordID = gfx.Item(2)

// keymapState is the Keymap page's filter and the chord being recorded. Only the window
// thread reads or writes it.
type keymapState struct {
	query ui.Field
	// recording is the action a chord is being recorded for; empty when none is.
	recording string
	// record is the field that has the keyboard while recording; it never keeps text.
	record ui.Field
	// focus asks the record field to take the keyboard in the next paint.
	focus bool
	// message is why the last recorded chord was refused, under its action.
	message, messageFor string
}

// keymapPage is the Keymap page: every action of the shortcut catalog with its keys, a
// filter by name or key, and for each action buttons to add a chord, remove one and go
// back to its defaults. A recorded chord another action holds is refused and the owner
// named; nothing is taken from another action silently. A change reaches the settings
// owner at once and the workbench dispatches the new keys from its next paint.
func (w *window) keymapPage(c ui.C) {
	t := &w.text.Keymap
	k := &w.keymap
	keys := w.sess.values.Keymap
	w.pageScroll(c, pageKeymap, func() {
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.TextField(c.Part("keymap-search"), &k.query, t.Search, t.SearchPlaceholder).Icon(icons.Search).Grow(1).MinWidth(0)
			if ui.Button(c.Part("keymap-reset-all"), t.ResetAll).Outline().Small().Disabled(len(keys) == 0).Clicked() {
				k.recording, k.message = "", ""
				w.setKeymap(nil)
			}
		})
		ui.Wrap(c, t.Help).FontSize(12).Color(w.pal.muted)
		query := strings.ToLower(strings.TrimSpace(k.query.Text()))
		shown := 0
		var group shortcuts.Group = -1
		var rows []shortcuts.Action
		flush := func() {
			if len(rows) == 0 {
				return
			}
			list := rows
			w.card(c.KeyInt(int(group)), group.Title(w.text), "", func() {
				for i, action := range list {
					if i > 0 {
						ui.Row(c).FillWidth().Height(1).Background(w.pal.line)
					}
					w.keymapRow(c.Key(action.ID), action, keys)
				}
			})
			rows = nil
		}
		for _, action := range shortcuts.Catalog {
			if query != "" && !w.keymapMatches(action, keys, query) {
				continue
			}
			if action.Group != group {
				flush()
				group = action.Group
			}
			rows = append(rows, action)
			shown++
		}
		flush()
		if shown == 0 {
			ui.Text(c, t.NoMatch).FontSize(12).Color(w.pal.muted)
		}
	})
}

// keymapMatches reports whether the filter finds action by its title, group or keys.
func (w *window) keymapMatches(action shortcuts.Action, keys shortcuts.Overrides, query string) bool {
	text := strings.ToLower(action.Title(w.text) + " " + action.Group.Title(w.text) + " " + keys.Label(action.ID) + " " + action.ID)
	for _, word := range strings.Fields(query) {
		if !strings.Contains(text, word) {
			return false
		}
	}
	return true
}

// keymapRow is one action: its title, a chip for each chord with a remove button, and the
// add and reset buttons; while recording, the field that takes the next chord.
func (w *window) keymapRow(c ui.C, action shortcuts.Action, keys shortcuts.Overrides) {
	t := &w.text.Keymap
	k := &w.keymap
	p := &w.pal
	list := keys.Effective(action)
	ui.Column(c).FillWidth().PadY(4).Gap(4).Children(func() {
		ui.Row(c).FillWidth().MinHeight(28).Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, action.Title(w.text)).FontSize(13).Color(p.text).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			if keys.Changed(action.ID) {
				ui.Text(c, t.Modified).FontSize(11).Color(p.muted).Shrink(0)
			}
			if len(list) == 0 && k.recording != action.ID {
				ui.Text(c, t.None).FontSize(12).Color(p.muted).Shrink(0)
			}
			for i, chord := range list {
				ui.Row(c.KeyInt(i)).Shrink(0).Height(22).PadX(6).Gap(2).Items(ui.Center).Radius(4).Background(p.sidebar).Stroke(1, p.line).Children(func() {
					ui.Text(c, shortcuts.Keycaps(chord)).FontSize(12).Color(p.text)
					if ui.Button(c.Part("remove"), t.Remove).Icon(icons.X).IconOnly().Ghost().Size(16, 16).Clicked() {
						rest := slices.Clone(list)
						rest = slices.Delete(rest, i, i+1)
						c.After(func() { w.setKeymap(w.sess.values.Keymap.With(action.ID, rest)) })
					}
				})
			}
			if k.recording == action.ID {
				w.keymapRecorder(c, action, list)
			} else if ui.Button(c.Part("add"), t.Add).Icon(icons.Plus).IconOnly().Ghost().Small().Clicked() {
				k.recording, k.focus, k.message = action.ID, true, ""
				k.record.SetText("")
			}
			if ui.Button(c.Part("reset"), t.Reset).Ghost().Small().Disabled(!keys.Changed(action.ID)).Clicked() {
				c.After(func() { w.setKeymap(w.sess.values.Keymap.Without(action.ID)) })
			}
		})
		if k.messageFor == action.ID && k.message != "" {
			ui.Wrap(c, k.message).FontSize(12).Color(p.danger)
		}
	})
}

// keymapRecorder is the field that takes the next chord for action: Escape alone cancels,
// a chord that would take plain typing or that another action holds is refused with the
// reason, and any other chord is added to the action's keys.
func (w *window) keymapRecorder(c ui.C, action shortcuts.Action, list []keymap.Chord) {
	t := &w.text.Keymap
	k := &w.keymap
	if k.record.Text() != "" {
		// Plain typing reaches the field as text; it never binds, so it is dropped.
		k.record.SetText("")
	}
	field := ui.TextFieldID(c, keymapRecordID, &k.record, t.Recording, t.RecordingHint).Width(180).Shrink(0)
	field.OnKey(func(event gfx.KeyEvent) gfx.EventResult {
		if event.Release {
			return gfx.EventResult{}
		}
		if event.Key == gfx.KeyEscape && event.Modifiers == 0 {
			k.recording, k.message = "", ""
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		chord, ok := keymap.FromEvent(event)
		if !ok {
			// A modifier on its own: wait for the key it goes with.
			return gfx.EventResult{Handled: true}
		}
		w.recordChord(action, list, chord)
		return gfx.EventResult{Handled: true, Repaint: true}
	})
	if k.focus {
		k.focus = false
		field.AutoFocus()
	}
	if ui.Button(c.Part("cancel"), t.Cancel).Ghost().Small().Clicked() {
		k.recording, k.message = "", ""
	}
}

// recordChord adds chord to action's keys, or says why it cannot.
func (w *window) recordChord(action shortcuts.Action, list []keymap.Chord, chord keymap.Chord) {
	t := &w.text.Keymap
	k := &w.keymap
	k.messageFor = action.ID
	if !shortcuts.Bindable(chord) {
		k.message = t.Unbindable
		return
	}
	keys := w.sess.values.Keymap
	if owner, taken := keys.Owner(chord, action.ID); taken {
		k.message = t.Conflict(shortcuts.Keycaps(chord), owner.Title(w.text))
		return
	}
	k.recording, k.message = "", ""
	if slices.Contains(list, chord) {
		return
	}
	w.setKeymap(keys.With(action.ID, append(slices.Clone(list), chord)))
}

// setKeymap stores the user's key changes and hands them to the settings owner.
func (w *window) setKeymap(value shortcuts.Overrides) {
	if w.sess.finished.Load() {
		return
	}
	if len(value) == 0 {
		value = nil
	}
	w.sess.values.Keymap = value
	if w.ctrl.opts.SetKeymap != nil {
		w.ctrl.opts.SetKeymap(value)
	}
}
