package settingswindow

import (
	"runtime"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

func TestGeneralAppearanceAppliesBeforeCloseAndRestore(t *testing.T) {
	var themes, languages []string
	w := newWindow(NewController(Options{
		SetTheme:    func(value string) { themes = append(themes, value) },
		SetLanguage: func(value string) { languages = append(languages, value) },
	}), Values{Language: "en"})
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	click := func(id gfx.ID) {
		t.Helper()
		for _, hit := range driver.Snapshot().Hits {
			if hit.ID == id {
				if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
		t.Fatalf("control %v was not found", id)
	}
	click(themeScope.At(2))
	if !slices.Equal(themes, []string{themeDark}) || len(languages) != 0 {
		t.Fatalf("appearance selection: themes=%v languages=%v", themes, languages)
	}
	click(languageScope.At(len(i18n.Languages) + 1))
	click(languageScope.At(languageIndex(i18n.Chinese.Code())))
	if !slices.Equal(languages, []string{i18n.Chinese.Code()}) || !slices.Equal(themes, []string{themeDark}) {
		t.Fatalf("language selection: themes=%v languages=%v", themes, languages)
	}
	click(restoreID)
	if !slices.Equal(themes, []string{themeDark, ""}) || !slices.Equal(languages, []string{i18n.Chinese.Code(), ""}) {
		t.Fatalf("restore: themes=%v languages=%v", themes, languages)
	}
	click(cancelID)
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
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	for _, hit := range driver.Snapshot().Hits {
		if hit.ID == restoreID {
			if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(themes, []string{""}) || !slices.Equal(languages, []string{""}) {
				t.Fatalf("restore did not clear stored values: themes=%v languages=%v", themes, languages)
			}
			return
		}
	}
	t.Fatal("restore control was not found")
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
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	click := func(id gfx.ID) {
		t.Helper()
		for _, hit := range driver.Snapshot().Hits {
			if hit.ID == id {
				if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
		t.Fatalf("control %v was not found", id)
	}
	click(languageScope.At(len(i18n.Languages) + 1))
	click(languageScope.At(languageIndex(i18n.Chinese.Code())))
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	for _, label := range driver.Snapshot().Labels {
		if label.Value == current.Settings.General {
			return
		}
	}
	t.Fatalf("settings window did not repaint with %q", current.Settings.General)
}

func TestGeneralInfoHoverClickAndKeyboard(t *testing.T) {
	w := newWindow(NewController(Options{Language: func() i18n.Language { return i18n.English }}), Values{})
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	id := infoScope.At(0)
	var trigger gfx.Hit
	for _, hit := range driver.Snapshot().Hits {
		if hit.ID == id {
			trigger = hit
		}
	}
	if trigger.ID.IsZero() || trigger.Label != i18n.Shared(i18n.English, "native.moreInformation") || trigger.Hint != w.text.Settings.AppearanceHelp {
		t.Fatalf("info accessibility = %+v", trigger)
	}
	for _, label := range driver.Snapshot().Labels {
		if label.Value == w.text.Settings.AppearanceHelp {
			t.Fatal("help is permanently visible")
		}
	}
	x, y := trigger.Bounds.X+trigger.Bounds.Width/2, trigger.Bounds.Y+trigger.Bounds.Height/2
	if err := driver.Move(x, y); err != nil {
		t.Fatal(err)
	}
	if err := driver.Advance(499 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if !w.info.Showing().IsZero() {
		t.Fatal("help appeared before the hover delay")
	}
	if err := driver.Advance(2 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if w.info.Showing() != id {
		t.Fatal("hover did not display the help")
	}
	if err := driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	if w.pinnedInfo != id {
		t.Fatal("click did not pin the help")
	}
	if err := driver.Move(2, 2); err != nil {
		t.Fatal(err)
	}
	if w.pinnedInfo != id {
		t.Fatal("moving away dismissed pinned help")
	}
	if err := driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if !w.pinnedInfo.IsZero() || w.sess.finished.Load() {
		t.Fatal("Escape did not close help without closing settings")
	}
	if err := driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	if err := driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if !w.pinnedInfo.IsZero() || w.sess.finished.Load() {
		t.Fatal("keyboard activation did not toggle help")
	}
	if err := driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	for _, hit := range driver.Snapshot().Hits {
		if hit.ID == searchID {
			if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
				t.Fatal(err)
			}
			break
		}
	}
	if !w.pinnedInfo.IsZero() || w.sess.finished.Load() {
		t.Fatal("outside click did not dismiss help without closing settings")
	}
}

func TestSettingsSearchUsesPlatformShortcutAndClears(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{})
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	modifier := gfx.ModifierControl
	if runtime.GOOS == "darwin" {
		modifier = gfx.ModifierMeta
	}
	if handled, err := driver.ShortcutChord(modifier, 'f'); err != nil || !handled {
		t.Fatalf("search shortcut handled=%v error=%v", handled, err)
	}
	if driver.Snapshot().Focused != searchID {
		t.Fatal("search field did not receive focus")
	}
	if err := driver.Type("Network"); err != nil {
		t.Fatal(err)
	}
	if w.search.Text() != "Network" || len(w.rows) != 2 || w.rows[1].page != pageNetwork {
		t.Fatalf("search=%q rows=%+v", w.search.Text(), w.rows)
	}
	if err := driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if w.search.Text() != "" || w.sess.finished.Load() {
		t.Fatal("Escape did not clear search without closing settings")
	}
}

func TestGeneralNarrowWindowKeepsSystemAppearanceVisible(t *testing.T) {
	w := newWindow(NewController(Options{SystemDark: func() bool { return true }}), Values{})
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	if err := driver.Resize(windowMinWidth, windowMinHeight); err != nil {
		t.Fatal(err)
	}
	want := w.themeLabels[0]
	for _, label := range driver.Snapshot().Labels {
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

// TestWindowControlsFollowTheTitleBar covers the buttons Viva draws in the custom title bar on
// Windows and Linux: unstyled, they took Viva's ink for its default dark clear color and were
// white on the light title bar. They must take the ink of the title bar and the language of
// the client, and follow the look when it changes.
func TestWindowControlsFollowTheTitleBar(t *testing.T) {
	w := newWindow(NewController(Options{Text: func() *i18n.Messages { return i18n.For(i18n.Chinese) }}),
		Values{Language: "zh-Hans", Theme: themeLight})
	config := w.config()
	if config.WindowControls == nil {
		t.Fatal("the settings window leaves its window buttons to Viva's default ink")
	}
	driver, err := app.NewDriver(config, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
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
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	check("dark", darkPalette().text)
}
