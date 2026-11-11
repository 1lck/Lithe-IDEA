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

// TestFontsUncheckingAPlaceGivesItAFontOfItsOwn covers the places of a font: unchecking
// Terminal in the one font of the default list splits it in two, the font of the Terminal
// keeps that place checked and cannot lose it, and checking Terminal again in the first font
// joins the two.
func TestFontsUncheckingAPlaceGivesItAFontOfItsOwn(t *testing.T) {
	var changed [][]fontprefs.Font
	w, d := fontsWindow(t, nil, nil, &changed)
	terminal := w.fontWords().scope(fontprefs.Terminal)

	boxes := fontHits(d, terminal, gfx.RoleCheckbox)
	if len(boxes) != 1 || !boxes[0].Checked || boxes[0].Disabled {
		t.Fatalf("the Terminal checkbox of the one font: %+v", boxes)
	}
	d.clickHit(boxes[0])
	if len(changed) != 1 {
		t.Fatalf("unchecking Terminal handed %d lists to the owner, want 1", len(changed))
	}
	requireFonts(t, "unchecking Terminal", changed[0], []fontprefs.Font{
		fontOf(fontprefs.Editor, fontprefs.Output),
		fontOf(fontprefs.Terminal),
	})

	fontsRepaint(d)
	boxes = fontHits(d, terminal, gfx.RoleCheckbox)
	if len(boxes) != 2 || boxes[0].Checked || boxes[0].Disabled || !boxes[1].Checked || !boxes[1].Disabled {
		t.Fatalf("the Terminal checkboxes of the two fonts: %+v", boxes)
	}

	d.clickHit(boxes[0])
	if len(changed) != 2 {
		t.Fatalf("checking Terminal again handed %d lists to the owner, want 2", len(changed))
	}
	requireFonts(t, "checking Terminal again", changed[1], fontprefs.Default())
	fontsRepaint(d)
	if got := fontHits(d, terminal, gfx.RoleCheckbox); len(got) != 1 {
		t.Fatalf("the joined list shows %d Terminal checkboxes, want 1", len(got))
	}
}

// TestFontsOverviewSeparateButtonGivesAPlaceItsOwnFont covers the buttons of the overview:
// each place that shares its font has one, it does what unchecking the place in its card
// does, and a place that has its font to itself no longer offers it.
func TestFontsOverviewSeparateButtonGivesAPlaceItsOwnFont(t *testing.T) {
	cases := []struct {
		scope fontprefs.Scope
		want  []fontprefs.Font
	}{
		{fontprefs.Editor, []fontprefs.Font{fontOf(fontprefs.Editor), fontOf(fontprefs.Terminal, fontprefs.Output)}},
		{fontprefs.Terminal, []fontprefs.Font{fontOf(fontprefs.Editor, fontprefs.Output), fontOf(fontprefs.Terminal)}},
		{fontprefs.Output, []fontprefs.Font{fontOf(fontprefs.Editor, fontprefs.Terminal), fontOf(fontprefs.Output)}},
	}
	for i, tc := range cases {
		t.Run(string(tc.scope), func(t *testing.T) {
			var changed [][]fontprefs.Font
			w, d := fontsWindow(t, nil, nil, &changed)
			label := i18n.Shared(w.marketLanguage(), "desktop.settings.fontsSeparate")
			buttons := fontHits(d, label, gfx.RoleButton)
			if len(buttons) != len(fontprefs.Scopes) {
				t.Fatalf("the overview has %d buttons, want one for each of the three places that share a font", len(buttons))
			}
			d.clickHit(buttons[i])
			if len(changed) != 1 {
				t.Fatalf("the button handed %d lists to the owner, want 1", len(changed))
			}
			requireFonts(t, "setting "+string(tc.scope)+" separately", changed[0], tc.want)
			fontsRepaint(d)
			if got := fontHits(d, label, gfx.RoleButton); len(got) != 2 {
				t.Fatalf("after the split the overview has %d buttons, want 2: the place with its own font has none", len(got))
			}
		})
	}
}
