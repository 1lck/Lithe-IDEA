package settingswindow

import (
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// fontsTall is the height of the window the Fonts tests open. The page scrolls, so it is
// tall enough to hold the overview and the cards of every font a test makes: no test has to
// scroll to reach a control.
const fontsTall = 1400

// fontsWindow opens the Fonts page with stored as the list in force. What the page hands to
// the owner is appended to changed. families is the loader of the installed families, nil for
// none.
func fontsWindow(t *testing.T, stored []fontprefs.Font, families func() []string, changed *[][]fontprefs.Font) (*window, *windowDriver) {
	t.Helper()
	w := newWindow(NewController(Options{
		MonospaceFamilies: families,
		SetFonts:          func(fonts []fontprefs.Font) { *changed = append(*changed, fonts) },
	}), Values{Fonts: stored})
	w.sess.page = pageFonts
	return w, openWindow(t, w, func(config *app.Config) { config.Height = fontsTall })
}

// fontsRepaint wakes the window and paints it once, so that the page is declared again from
// the list the last click stored.
func fontsRepaint(d *windowDriver) {
	d.t.Helper()
	d.w.inv.Invalidate()
	d.pump()
}

// fontHits are the controls of one role with the accessible name label, in paint order: the
// same control of each font card comes in the order of the cards, which the single-label
// lookup of the driver cannot tell apart.
func fontHits(d *windowDriver, label string, role gfx.Role) []gfx.Hit {
	var out []gfx.Hit
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Label == label && hit.Role == role && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			out = append(out, hit)
		}
	}
	return out
}

// fontOf is a font of the default size for the scopes, which are given in the order of
// fontprefs.Scopes. It writes the lists the tests expect.
func fontOf(scopes ...fontprefs.Scope) fontprefs.Font {
	return fontprefs.Font{Size: fontprefs.DefaultSize, Scopes: scopes}
}

// requireFonts fails the test unless got is exactly want. It compares field by field, not
// with fontprefs.Equal, which normalizes both sides and so would accept a list that was not
// normalized.
func requireFonts(t *testing.T, what string, got, want []fontprefs.Font) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: got %+v, want %+v", what, got, want)
	}
}

// TestFontsPageWritesNothingWhenOpenedOrPainted covers the rule that opening a settings page
// changes no setting: showing the list, taking the installed families and painting again hand
// nothing to the owner, not even for a stored family the machine does not have.
func TestFontsPageWritesNothingWhenOpenedOrPainted(t *testing.T) {
	cases := []struct {
		name   string
		stored []fontprefs.Font
	}{
		{"the default list", nil},
		{"a family the machine lacks", []fontprefs.Font{{Family: "Ghost Mono", Size: 15, LineSpacing: 1.6, Ligatures: true, Scopes: []fontprefs.Scope{fontprefs.Editor}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var changed [][]fontprefs.Font
			w, d := fontsWindow(t, tc.stored, func() []string { return []string{"Menlo", "Monaco"} }, &changed)
			d.until("the installed fonts", func() bool { return w.fonts.loaded })
			for range 3 {
				fontsRepaint(d)
			}
			if len(changed) != 0 {
				t.Fatalf("opening and painting the page handed %+v to the owner", changed)
			}
			requireFonts(t, "the list the page shows", w.sess.values.Fonts, fontprefs.Normalize(tc.stored))
		})
	}
}

// fontsControl is the one control of role named by the shared text id, as the Fonts page
// shows it now.
func fontsControl(t *testing.T, d *windowDriver, w *window, id string, role gfx.Role) gfx.Hit {
	t.Helper()
	hits := fontHits(d, i18n.Shared(w.fontWords().language, id), role)
	if len(hits) != 1 {
		t.Fatalf("the page shows %d controls named %q, want 1", len(hits), id)
	}
	return hits[0]
}

// fontsPlace is the checkbox of a place in the overview.
func fontsPlace(t *testing.T, d *windowDriver, w *window, scope fontprefs.Scope) gfx.Hit {
	t.Helper()
	hits := fontHits(d, w.fontWords().scope(scope), gfx.RoleCheckbox)
	if len(hits) != 1 {
		t.Fatalf("the overview shows %d checkboxes for %s, want 1", len(hits), scope)
	}
	return hits[0]
}

// fontsClick clicks a control and paints the page again from what the click left.
func fontsClick(t *testing.T, d *windowDriver, hit gfx.Hit) {
	t.Helper()
	d.clickHit(hit)
	fontsRepaint(d)
}

// requireFontButtons fails the test unless Save and Revert are enabled as given.
func requireFontButtons(t *testing.T, d *windowDriver, w *window, what string, save, revert bool) {
	t.Helper()
	gotSave := !fontsControl(t, d, w, "ui.save", gfx.RoleButton).Disabled
	gotRevert := !fontsControl(t, d, w, "desktop.settings.network.revert", gfx.RoleButton).Disabled
	if gotSave != save || gotRevert != revert {
		t.Fatalf("%s: Save enabled %v, Revert enabled %v; want %v and %v", what, gotSave, gotRevert, save, revert)
	}
}

// TestFontsSaveGivesTheCheckedPlacesTheLook covers the flow of the page: the places that share
// the editor's font start checked, unchecking one and stepping the size hand nothing to the
// owner, and Save gives the checked places the new size while the unchecked one keeps its font.
func TestFontsSaveGivesTheCheckedPlacesTheLook(t *testing.T) {
	var changed [][]fontprefs.Font
	w, d := fontsWindow(t, nil, nil, &changed)
	for _, scope := range fontprefs.Scopes {
		if !fontsPlace(t, d, w, scope).Checked {
			t.Fatalf("%s is not checked at first, though every place shares the editor's font", scope)
		}
	}
	requireFontButtons(t, d, w, "before any change", false, false)

	fontsClick(t, d, fontsPlace(t, d, w, fontprefs.Terminal))
	if fontsPlace(t, d, w, fontprefs.Terminal).Checked {
		t.Fatal("clicking Terminal left it checked")
	}
	if !d.text(w.fontWords().scopes([]fontprefs.Scope{fontprefs.Editor, fontprefs.Output})) {
		t.Fatal("the card's title does not name the checked places")
	}
	larger := fontsControl(t, d, w, "desktop.settings.fontsSizeIncrease", gfx.RoleButton)
	fontsClick(t, d, larger)
	fontsClick(t, d, larger)
	if len(changed) != 0 {
		t.Fatalf("checking places and stepping the size handed %+v to the owner before Save", changed)
	}
	requireFontButtons(t, d, w, "after stepping the size", true, true)
	save := fontsControl(t, d, w, "ui.save", gfx.RoleButton)
	revert := fontsControl(t, d, w, "desktop.settings.network.revert", gfx.RoleButton)
	if right := save.Bounds.X + save.Bounds.Width; revert.Bounds.X >= save.Bounds.X || right <= larger.Bounds.X+larger.Bounds.Width {
		t.Fatalf("Save at %+v and Revert at %+v, want Save last, at the right of the card past the size buttons at %+v", save.Bounds, revert.Bounds, larger.Bounds)
	}

	fontsClick(t, d, fontsControl(t, d, w, "ui.save", gfx.RoleButton))
	if len(changed) != 1 {
		t.Fatalf("Save handed %d lists to the owner, want 1", len(changed))
	}
	saved := fontOf(fontprefs.Editor, fontprefs.Output)
	saved.Size = 15
	requireFonts(t, "saving 15 pt for the editor and the run output", changed[0], []fontprefs.Font{saved, fontOf(fontprefs.Terminal)})
	requireFontButtons(t, d, w, "after saving", false, false)
	if !d.text(w.fontWords().sizeValue(15)) {
		t.Fatal("after saving, the card does not show the saved size")
	}
}

// TestFontsSavingAPlacesLookForAnotherJoinsThem covers checking a place whose font differs: the
// card keeps showing the font of the first checked place, Save gives it to the newly checked
// one too, and places that end with the same look are joined into one font.
func TestFontsSavingAPlacesLookForAnotherJoinsThem(t *testing.T) {
	editor := fontOf(fontprefs.Editor)
	editor.Size = 15
	var changed [][]fontprefs.Font
	w, d := fontsWindow(t, []fontprefs.Font{editor, fontOf(fontprefs.Terminal, fontprefs.Output)}, nil, &changed)
	if !fontsPlace(t, d, w, fontprefs.Editor).Checked || fontsPlace(t, d, w, fontprefs.Terminal).Checked || fontsPlace(t, d, w, fontprefs.Output).Checked {
		t.Fatal("at first only the editor, which has its font to itself, should be checked")
	}
	requireFontButtons(t, d, w, "with the editor checked", false, false)

	fontsClick(t, d, fontsPlace(t, d, w, fontprefs.Terminal))
	if !d.text(w.fontWords().sizeValue(15)) {
		t.Fatal("checking Terminal changed the size the card shows, want the editor's")
	}
	requireFontButtons(t, d, w, "with the terminal checked too", true, false)
	fontsClick(t, d, fontsControl(t, d, w, "ui.save", gfx.RoleButton))
	shared := fontOf(fontprefs.Editor, fontprefs.Terminal)
	shared.Size = 15
	output := fontOf(fontprefs.Output)
	if len(changed) != 1 {
		t.Fatalf("Save handed %d lists, want 1", len(changed))
	}
	requireFonts(t, "giving the terminal the editor's font", changed[0], []fontprefs.Font{shared, output})

	fontsClick(t, d, fontsPlace(t, d, w, fontprefs.Output))
	fontsClick(t, d, fontsControl(t, d, w, "ui.save", gfx.RoleButton))
	every := fontprefs.Default()
	every[0].Size = 15
	if len(changed) != 2 {
		t.Fatalf("the second Save handed %d lists in all, want 2", len(changed))
	}
	requireFonts(t, "giving every place the editor's font", changed[1], every)
}

// TestFontsRevertDropsTheUnsavedLook covers Revert, which brings the card back to the stored
// font without handing anything to the owner, and a card with no place checked, whose title
// says so and whose Save stays off whatever it is set to.
func TestFontsRevertDropsTheUnsavedLook(t *testing.T) {
	var changed [][]fontprefs.Font
	w, d := fontsWindow(t, nil, nil, &changed)
	fontsClick(t, d, fontsControl(t, d, w, "desktop.settings.fontsSizeDecrease", gfx.RoleButton))
	fontsClick(t, d, fontsControl(t, d, w, "settings.editor.fontLigatures", gfx.RoleSwitch))
	if !w.fontEdit.draft.Ligatures || w.fontEdit.draft.Size != fontprefs.DefaultSize-1 {
		t.Fatalf("the card's look is %+v, want ligatures on at one point smaller", w.fontEdit.draft)
	}
	requireFontButtons(t, d, w, "after the edits", true, true)

	fontsClick(t, d, fontsControl(t, d, w, "desktop.settings.network.revert", gfx.RoleButton))
	if len(changed) != 0 {
		t.Fatalf("Revert handed %+v to the owner", changed)
	}
	if w.fontEdit.draft.Ligatures || w.fontEdit.draft.Size != fontprefs.DefaultSize {
		t.Fatalf("after Revert the card's look is %+v, want the stored font", w.fontEdit.draft)
	}
	requireFontButtons(t, d, w, "after Revert", false, false)

	for _, scope := range fontprefs.Scopes {
		fontsClick(t, d, fontsPlace(t, d, w, scope))
	}
	if !d.text(i18n.Shared(w.fontWords().language, "desktop.settings.fontsNoneChecked")) {
		t.Fatal("with no place checked the card's title does not say so")
	}
	fontsClick(t, d, fontsControl(t, d, w, "desktop.settings.fontsSizeIncrease", gfx.RoleButton))
	requireFontButtons(t, d, w, "with no place checked", false, true)
	if len(changed) != 0 {
		t.Fatalf("with no place checked the page handed %+v to the owner", changed)
	}
}
