package settingswindow

import (
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// hintHit finds the control whose tip says hint.
func (d *windowDriver) hintHit(hint string) gfx.Hit {
	d.t.Helper()
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Hint == hint && !hit.IsLabel && !hit.Backdrop {
			return hit
		}
	}
	d.t.Fatalf("no control with the tip %q", hint)
	return gfx.Hit{}
}

// showsHelp reports whether help is on the screen. A tip wraps its sentence in lines, so a
// line that starts it counts.
func (d *windowDriver) showsHelp(help string) bool {
	for _, text := range d.driver.Snapshot().Texts {
		if len(text.Value) >= 8 && strings.HasPrefix(help, text.Value) {
			return true
		}
	}
	return false
}

func TestGeneralAppearanceAppliesBeforeCloseAndRestore(t *testing.T) {
	var themes, languages []string
	w := newWindow(NewController(Options{
		SetTheme:    func(value string) { themes = append(themes, value) },
		SetLanguage: func(value string) { languages = append(languages, value) },
	}), Values{Language: "en"})
	d := openWindow(t, w)
	d.click("Dark")
	if !slices.Equal(themes, []string{themeDark}) || len(languages) != 0 {
		t.Fatalf("appearance selection: themes=%v languages=%v", themes, languages)
	}
	d.click("Language")
	d.click(i18n.Chinese.Native())
	if !slices.Equal(languages, []string{i18n.Chinese.Code()}) || !slices.Equal(themes, []string{themeDark}) {
		t.Fatalf("language selection: themes=%v languages=%v", themes, languages)
	}
	d.click("Restore Defaults")
	if !slices.Equal(themes, []string{themeDark, ""}) || !slices.Equal(languages, []string{i18n.Chinese.Code(), ""}) {
		t.Fatalf("restore: themes=%v languages=%v", themes, languages)
	}
	d.click("Cancel")
	if !slices.Equal(themes, []string{themeDark, ""}) || !slices.Equal(languages, []string{i18n.Chinese.Code(), ""}) {
		t.Fatalf("closing changed settings: themes=%v languages=%v", themes, languages)
	}
	w.setTheme(themeLight, false)
	if len(themes) != 2 {
		t.Fatal("closed window applied a late change")
	}
}

func TestGeneralRestoreClearsUnknownStoredValues(t *testing.T) {
	var themes, languages []string
	w := newWindow(NewController(Options{
		SetTheme:    func(value string) { themes = append(themes, value) },
		SetLanguage: func(value string) { languages = append(languages, value) },
	}), Values{Language: "unknown-language", Theme: "unknown-theme"})
	d := openWindow(t, w)
	d.click("Restore Defaults")
	if !slices.Equal(themes, []string{""}) || !slices.Equal(languages, []string{""}) {
		t.Fatalf("restore did not clear stored values: themes=%v languages=%v", themes, languages)
	}
}

func TestGeneralLanguageChangeRepaintsOpenWindow(t *testing.T) {
	current := i18n.For(i18n.English)
	var w *window
	c := NewController(Options{
		Text: func() *i18n.Messages { return current },
		SetLanguage: func(code string) {
			if code != i18n.Chinese.Code() {
				t.Fatalf("selected language = %q", code)
			}
			current = i18n.For(i18n.Chinese)
			w.inv.Invalidate()
		},
	})
	w = newWindow(c, Values{Language: i18n.English.Code()})
	d := openWindow(t, w)
	d.click("Language")
	d.click(i18n.Chinese.Native())
	d.pump()
	if !d.text(current.Settings.General) {
		t.Fatalf("settings window did not repaint with %q", current.Settings.General)
	}
}

func TestGeneralInfoHoverClickAndKeyboard(t *testing.T) {
	w := newWindow(NewController(Options{Language: func() i18n.Language { return i18n.English }}), Values{})
	d := openWindow(t, w)
	help := w.text.Settings.AppearanceHelp
	trigger := d.hintHit(help)
	if trigger.Label != i18n.Shared(i18n.English, "native.moreInformation") {
		t.Fatalf("info accessibility = %+v", trigger)
	}
	if d.showsHelp(help) {
		t.Fatal("help is permanently visible")
	}
	x, y := trigger.Bounds.X+trigger.Bounds.Width/2, trigger.Bounds.Y+trigger.Bounds.Height/2
	// ui.Tooltip shows its tip as soon as the pointer rests on the control; the 500 ms hover
	// delay of the Frame version is Viva's constant now (components.HoverTooltipDelay).
	if err := d.driver.Move(x, y); err != nil {
		t.Fatal(err)
	}
	if !d.showsHelp(help) {
		t.Fatal("hover did not display the help")
	}
	if err := d.driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	if err := d.driver.Move(2, 2); err != nil {
		t.Fatal(err)
	}
	if !d.showsHelp(help) {
		t.Fatal("moving away dismissed pinned help")
	}
	d.key(gfx.KeyEscape)
	if d.showsHelp(help) || w.sess.finished.Load() {
		t.Fatal("Escape did not close help without closing settings")
	}
	if err := d.driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	if !d.showsHelp(help) {
		t.Fatal("click did not pin the help")
	}
	d.key(gfx.KeyEnter)
	if err := d.driver.Move(2, 2); err != nil {
		t.Fatal(err)
	}
	if d.showsHelp(help) || w.sess.finished.Load() {
		t.Fatal("keyboard activation did not toggle help")
	}
	if err := d.driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	d.click("Search settings")
	if d.showsHelp(help) || w.sess.finished.Load() {
		t.Fatal("outside click did not dismiss help without closing settings")
	}
}

func TestSettingsSearchUsesPlatformShortcutAndClears(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{})
	d := openWindow(t, w)
	modifier := gfx.ModifierControl
	if runtime.GOOS == "darwin" {
		modifier = gfx.ModifierMeta
	}
	if handled, err := d.driver.ShortcutChord(modifier, 'f'); err != nil || !handled {
		t.Fatalf("search shortcut handled=%v error=%v", handled, err)
	}
	if d.driver.Snapshot().Focused != searchID {
		t.Fatal("search field did not receive focus")
	}
	d.typeText("Network")
	if w.searchField.Text() != "Network" || len(w.rows) != 2 || w.rows[1].page != pageNetwork {
		t.Fatalf("search=%q rows=%+v", w.searchField.Text(), w.rows)
	}
	d.key(gfx.KeyEscape)
	if w.searchField.Text() != "" || w.sess.finished.Load() {
		t.Fatal("Escape did not clear search without closing settings")
	}
	d.key(gfx.KeyEscape)
	if !w.sess.finished.Load() {
		t.Fatal("Escape with an empty search did not cancel")
	}
}

func TestGeneralNarrowWindowKeepsSystemAppearanceVisible(t *testing.T) {
	w := newWindow(NewController(Options{SystemDark: func() bool { return true }}), Values{})
	d := openWindow(t, w)
	if err := d.driver.Resize(windowMinWidth, windowMinHeight); err != nil {
		t.Fatal(err)
	}
	want := w.themeLabels[0]
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value != want {
			continue
		}
		if label.Clipped && (label.Bounds.X < label.Clip.X || label.Bounds.X+label.Bounds.Width > label.Clip.X+label.Clip.Width+0.5) {
			t.Fatalf("system appearance label is clipped: %+v", label)
		}
		return
	}
	t.Fatalf("system appearance label %q is missing", want)
}

// TestEnterIsOKOnlyWhereNoControlTakesIt covers Enter: with nothing focused it presses OK, as
// the default button does in a dialog, and with the focus on a control the control keeps it.
func TestEnterIsOKOnlyWhereNoControlTakesIt(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{})
	d := openWindow(t, w)
	d.click("Search settings")
	d.key(gfx.KeyEnter)
	if w.sess.finished.Load() {
		t.Fatal("Enter in the search field pressed OK")
	}
	w2 := newWindow(NewController(Options{}), Values{})
	d2 := openWindow(t, w2)
	d2.key(gfx.KeyEnter)
	if !w2.sess.finished.Load() {
		t.Fatal("Enter with nothing focused did not press OK")
	}
}

// TestWindowControlsFollowTheTitleBar covers the buttons Viva draws in the custom title bar on
// Windows and Linux: unstyled, they took Viva's ink for its default dark clear color and were
// white on the light title bar. They must take the ink of the title bar and the language of
// the client, and follow the look when it changes.
func TestWindowControlsFollowTheTitleBar(t *testing.T) {
	w := newWindow(NewController(Options{Text: func() *i18n.Messages { return i18n.For(i18n.Chinese) }}),
		Values{Language: "zh-Hans", Theme: themeLight})
	d := openWindow(t, w)
	config := w.config()
	if config.WindowControls == nil {
		t.Fatal("the settings window leaves its window buttons to Viva's default ink")
	}
	check := func(look string, ink gfx.Color) {
		t.Helper()
		style := config.WindowControls()
		if style.Foreground != ink || style.Minimize != "最小化" {
			t.Fatalf("%s look: glyph color %v and minimize name %q, want %v and %q", look, style.Foreground, style.Minimize, ink, "最小化")
		}
	}
	check("light", lightPalette().text)
	w.sess.values.Theme = themeDark
	w.inv.Invalidate()
	d.pump()
	check("dark", darkPalette().text)
}
